#!/usr/bin/env ruby

require 'fileutils'
require 'optimist'
require 'dbus'
require 'json'
require 'open3'
require 'date'

class MountError < StandardError; end

BACKUP_DIR = "/home/#{ENV['USER']}/cpapshare-data/".freeze
POLKIT_RULE_PATH = '/etc/polkit-1/rules.d/10-udisks2.rules'.freeze
CONFIG_FILE = "#{File.dirname File.absolute_path(__FILE__)}/config.json".freeze

class UsbBackup
  def load_config
    config = { 'copy_type' => 'raw' }

    unless File.exist?(CONFIG_FILE)
      warn "Configuration file #{CONFIG_FILE} not found, using defaults"
      return config
    end

    puts "Reloading configuration from #{CONFIG_FILE}"

    begin
      config.merge!(JSON.parse(File.read(CONFIG_FILE)))
    rescue JSON::ParserError => e
      puts "Warning: Invalid JSON in config file, using defaults: #{e.message}"
    end

    config
  end

  def wait_for_mount!
    puts 'Wait for device...'

    bus = DBus::SystemBus.instance
    udisks = bus.service('org.freedesktop.UDisks2')
    object_manager = udisks.object('/org/freedesktop/UDisks2')
    object_manager.default_iface = 'org.freedesktop.DBus.ObjectManager'
    object_manager.on_signal('InterfacesAdded') do |_path, interfaces|
      if interfaces.key?('org.freedesktop.UDisks2.Block')
        block_device = interfaces['org.freedesktop.UDisks2.Block']
        @device = block_device['Device'].pack('C*').strip

        puts 'New block device detected:'
        puts "Device: #{@device}"

        if interfaces.key?('org.freedesktop.UDisks2.Filesystem')
          # Check if it's a filesystem
          puts 'Device is a filesystem and ready to be mounted!'

          _, stderr, status = Open3.capture3('udisksctl', 'mount', '-b', @device)

          unless status.success?
            puts "Mount failed: #{stderr.strip}"
            raise MountError, "Failed to mount device #{@device}: #{stderr.strip}"
          end

          # Find the mount point from /proc/mounts
          File.foreach('/proc/mounts') do |line|
            if line.start_with?(@device)
              @mount_point = line.split[1] # Get the mount point
              puts "Successfully mounted #{@device} at #{@mount_point}"
              return @mount_point
            end
          end
          raise MountError, "Mount succeeded but could not find mount point for #{@device}"
        end
      end
    end

    # Main loop to keep the script running
    main = DBus::Main.new
    main << bus
    main.run
  end

  def copy_contents
    # Reload configuration fresh each time for immediate config changes
    @config = load_config

    puts "Copy sdcard contents to #{BACKUP_DIR}"

    FileUtils.mkdir_p(BACKUP_DIR) unless Dir.exist?(BACKUP_DIR)

    return copy_with_dates if @config['copy_type'] == 'dates'

    copy_raw if @config['copy_type'] == 'raw'
  end

  def copy_raw
    puts 'Performing raw copy of all files'
    begin
      rsync_copy(@mount_point, BACKUP_DIR)
      puts 'Raw copy completed successfully'
      true
    rescue StandardError => e
      puts "Raw copy failed: #{e.message}"
      false
    end
  end

  def copy_with_dates
    puts 'Performing dates-based copy'

    datalog_path = File.join(@mount_point, 'DATALOG')
    unless Dir.exist?(datalog_path)
      warn 'DATALOG directory not found, not a Resmed sdcard skipping copy'
      return false
    end

    source_date_dirs = Dir.glob(File.join(datalog_path, '*'))
                          .select { |path| File.directory?(path) }
                          .map { |path| File.basename(path) }
                          .select { |entry| entry.match?(/^\d{8}$/) } # Match YYYYMMDD
                          .map { |date_str| DateTime.parse(date_str) }
                          .sort

    if source_date_dirs.empty?
      warn 'No date directories found in DATALOG, skipping copy'
      return false
    end

    # Matches YYYY-MM-DD...
    last_saved_date =
      if Dir.exist?(BACKUP_DIR)
        Dir.entries(BACKUP_DIR)
           .select { |entry| File.directory?(File.join(BACKUP_DIR, entry)) }
           .select { |entry| entry.match?(/^\d{4}-\d{2}-\d{2}/) } # Matches YYYY-MM-DD...
           .flat_map { |dir_name| dir_name.split('_') }
           .map { |date_str| DateTime.parse(date_str) }
           .max
      end
    last_saved_date ||= DateTime.new(1970, 1, 1)

    puts "Last saved date: #{last_saved_date.to_date.iso8601}"
    # Filter date directories to only include new ones
    fresh_dirs = if last_saved_date
                   source_date_dirs.select do |dir_date|
                     dir_date > last_saved_date
                   end
                 else
                   source_date_dirs
                 end || []

    if fresh_dirs.empty?
      warn 'No new dates found, skipping copy'
      return
    end

    first_date = fresh_dirs.first
    last_date = fresh_dirs.last

    dest_dir_name = if first_date == last_date
                      first_date.to_date.iso8601
                    else
                      "#{first_date.to_date.iso8601}_#{last_date.to_date.iso8601}"
                    end

    dest_path = File.join(BACKUP_DIR, dest_dir_name)
    puts "Creating backup directory: #{dest_dir_name}"
    puts "Date range: #{first_date.to_date.iso8601} to #{last_date.to_date.iso8601} (#{fresh_dirs.length} new days)"

    FileUtils.mkdir_p(dest_path) unless Dir.exist?(dest_path)

    begin
      copy_with_filter(@mount_point, dest_path, last_saved_date)
      puts 'Dates-based copy completed successfully'
    rescue StandardError => e
      warn "Dates-based copy failed: #{e.message}"
    end
  end

  def unmount_device
    puts 'Unmount sdcard'

    _, stderr, status = Open3.capture3('udisksctl', 'unmount', '-b', @device)
    if status.success?
      puts "Successfully unmounted #{@device}"
    else
      warn "Unmount failed: #{stderr.strip}"
    end
  end

  def run_callback
    callback_file = "#{File.dirname File.absolute_path(__FILE__)}/post_backup.sh"
    system(callback_file) if File.exist?(callback_file)
  end

  private

  def rsync_copy(source, destination)
    raise 'Source or Destination incorrect' if source.strip.empty? || destination.strip.empty?

    FileUtils.mkdir_p(destination) unless Dir.exist?(destination)

    cmd = ['rsync', '-ah', '--update', "#{source}/", "#{destination}/"]

    puts "Running rsync: #{cmd.join(' ')}"

    _, stderr, status = Open3.capture3(*cmd)

    raise "rsync failed with exit code #{status.exitstatus}: #{stderr}" unless status.success?

    puts 'rsync completed successfully'
  end

  def copy_with_filter(source, destination, last_saved_date = nil)
    FileUtils.mkdir_p(destination) unless Dir.exist?(destination)

    copy_directory_filtered(source, destination, last_saved_date)
  end

  def copy_directory_filtered(source, destination, last_saved_date = nil, relative_path = '')
    Dir.foreach(source) do |entry|
      next if ['.', '..'].include?(entry)

      source_path = File.join(source, entry)
      dest_path = File.join(destination, entry)
      entry_relative_path = File.join(relative_path, entry)

      if relative_path == '/DATALOG'
        match = source_path.match(%r{^.*DATALOG/(\d+)$})
        next unless match && match[1]

        if DateTime.parse(match[1]) <= last_saved_date
          puts "Skipping old DATALOG folder: #{entry}"
          next
        end
      end

      if File.directory?(source_path)
        FileUtils.mkdir_p(dest_path) unless Dir.exist?(dest_path)
        copy_directory_filtered(source_path, dest_path, last_saved_date, entry_relative_path)
      elsif !File.exist?(dest_path) || File.mtime(source_path) > File.mtime(dest_path)
        FileUtils.cp(source_path, dest_path)
      end
    end
  end
end

opts = Optimist.options do
  banner <<~EOS
    A script to backup CPAP data before sharing on network.

    Usage:
           #{File.basename($PROGRAM_NAME)} [options]
    where [options] are:
  EOS

  opt :install, 'Install the polkit rule',
      short: '-i',
      type: :bool
  opt :uninstall, 'Remove the polkit rule',
      short: '-u',
      type: :bool
end

Optimist.die "Can't specify both --install and --uninstall" if opts[:install] && opts[:uninstall]

backup = UsbBackup.new

if opts[:install]
  unless Process.uid.zero?
    puts 'Installation requires root privileges. Please run with sudo.'
    exit 1
  end

  # To let normal user mount the device
  polkit_rule = <<~EOS
    polkit.addRule(function(action, subject) {
        if ((action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
             action.id == "org.freedesktop.udisks2.filesystem-mount-other-seat" ||
             action.id == "org.freedesktop.udisks2.filesystem-mount") &&
            subject.isInGroup("sudo")) {
            return polkit.Result.YES;
        }
    });
  EOS

  File.write(POLKIT_RULE_PATH, polkit_rule)
  FileUtils.chmod(0o644, POLKIT_RULE_PATH)
  puts "Polkit rule installed to #{POLKIT_RULE_PATH}"
  # Reload polkit rules
  warn 'Warning: Failed to restart polkit' unless system('systemctl restart polkit')

elsif opts[:uninstall]
  if File.exist?(POLKIT_RULE_PATH)
    File.delete(POLKIT_RULE_PATH)
    puts "Polkit rule uninstalled from #{POLKIT_RULE_PATH}"
  end
else
  begin
    loop do
      backup.wait_for_mount!
      backup.copy_contents
      backup.unmount_device
      backup.run_callback
    rescue MountError => e
      puts "Mount error: #{e.message}"
    end
  rescue Interrupt
    puts 'Stopping CPAPShare...'
  end
end
