#!/usr/bin/env ruby

require 'fileutils'
require 'optimist'
require 'dbus'
require 'json'

BACKUP_DIR = "/home/#{ENV['USER']}/cpapshare-data/".freeze
POLKIT_RULE_PATH = '/etc/polkit-1/rules.d/10-udisks2.rules'.freeze
CONFIG_FILE = "#{File.dirname File.absolute_path(__FILE__)}/config.json".freeze

class UsbBackup
  def initialize
    # Don't load config at startup, load it fresh each time
  end

  def load_config
    config = {}
    if File.exist?(CONFIG_FILE)
      begin
        config = JSON.parse(File.read(CONFIG_FILE))
      rescue JSON::ParserError => e
        puts "Warning: Invalid JSON in config file, using defaults: #{e.message}"
        config = {}
      end
    end

    # Set default for copy_type if not present
    config['copy_type'] ||= 'raw'

    # Set default for delete_after_copy if not present
    config['delete_after_copy'] = false if config['delete_after_copy'].nil?

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

          # Use udisksctl to mount the device
          mount_result = `udisksctl mount -b #{@device}`
          if $?.success?
            # Find the mount point from /proc/mounts
            File.foreach('/proc/mounts') do |line|
              if line.start_with?(@device)
                @mount_point = line.split[1] # Get the mount point
                puts "Successfully mounted #{@device} at #{@mount_point}"
                return @mount_point
              end
            end
            puts 'Mount succeeded but could not find mount point'
            return nil
          else
            puts "Mount failed: #{mount_result.strip}"
            return nil
          end
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

    if File.exist?(CONFIG_FILE)
      puts "Configuration reloaded from #{CONFIG_FILE}"
    else
      warn "Configuration file #{CONFIG_FILE} not found, using defaults"
    end

    puts 'Configuration:'
    puts "\tcopy_type: #{@config['copy_type']}"
    puts "\tdelete_after_copy: #{@config['delete_after_copy']}"

    puts "Copy sdcard contents to #{BACKUP_DIR}"

    FileUtils.mkdir_p(BACKUP_DIR) unless Dir.exist?(BACKUP_DIR)

    copy_success = false
    begin
      copy_success = case @config['copy_type']
                     when 'dates'
                       copy_with_dates
                     else
                       copy_raw
                     end

      # Delete DATALOG directory after successful copy if configured
      delete_datalog_after_copy if copy_success && @config['delete_after_copy']
    rescue StandardError => e
      puts "Error during copy operation: #{e.message}"
      copy_success = false
    end

    copy_success
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
      puts 'DATALOG directory not found, skipping copy'
      return false
    end

    # Get all subdirectories in DATALOG and sort them as integers
    date_dirs = Dir.entries(datalog_path)
                   .select { |entry| File.directory?(File.join(datalog_path, entry)) && entry != '.' && entry != '..' }
                   .select { |entry| entry.match?(/^\d+$/) } # Only numeric directory names
                   .sort_by(&:to_i)

    if date_dirs.empty?
      puts 'No date directories found in DATALOG, skipping copy'
      return false
    end

    first_date = date_dirs.first
    last_date = date_dirs.last

    # Helper method to format date from YYYYMMDD to YYYY.MM.DD
    def format_date(date_str)
      return date_str unless date_str.length == 8 && date_str.match?(/^\d{8}$/)

      "#{date_str[0..3]}.#{date_str[4..5]}.#{date_str[6..7]}"
    end

    # Create destination directory name
    dest_dir_name = if first_date == last_date
                      format_date(first_date)
                    else
                      "#{format_date(first_date)}-#{format_date(last_date)}"
                    end

    dest_path = File.join(BACKUP_DIR, dest_dir_name)
    puts "Creating backup directory: #{dest_dir_name}"
    puts "Date range: #{first_date} to #{last_date} (#{date_dirs.length} days)"

    FileUtils.mkdir_p(dest_path) unless Dir.exist?(dest_path)

    begin
      # Copy entire contents of the mount point to the destination
      rsync_copy(@mount_point, dest_path)
      puts 'Dates-based copy completed successfully'
      true
    rescue StandardError => e
      puts "Dates-based copy failed: #{e.message}"
      false
    end
  end

  def delete_datalog_after_copy
    datalog_path = File.join(@mount_point, 'DATALOG')

    unless Dir.exist?(datalog_path)
      puts 'DATALOG directory not found, skipping deletion'
      return
    end

    # Check if mount point is writable by testing file creation
    test_file = File.join(@mount_point, '.cpapshare_write_test')
    begin
      File.write(test_file, 'test')
      File.delete(test_file) if File.exist?(test_file)
      puts 'Mount point is writable, proceeding with deletion...'
    rescue StandardError => e
      puts "Mount point is not writable, cannot delete DATALOG: #{e.message}"
      puts "SD card may be mounted read-only or filesystem doesn't support deletion"
      return
    end

    puts 'Deleting DATALOG directory from source after successful copy...'
    begin
      # Use Ruby's FileUtils without sudo - this should work if mount is writable
      FileUtils.rm_rf(datalog_path)

      # Verify deletion
      if Dir.exist?(datalog_path)
        puts 'Warning: DATALOG directory still exists after deletion attempt'
        puts 'This may be due to filesystem restrictions or the device being remounted read-only'

        # Try to understand why deletion failed
        begin
          entries = Dir.entries(datalog_path).reject { |e| ['.', '..'].include?(e) }
          puts "Directory still contains #{entries.length} items: #{entries.first(3).join(', ')}#{entries.length > 3 ? '...' : ''}"
        rescue StandardError => e
          puts "Could not read directory contents: #{e.message}"
        end
      else
        puts 'DATALOG directory successfully deleted from source'
      end
    rescue StandardError => e
      puts "Error deleting DATALOG directory: #{e.message}"
      puts 'This is likely due to filesystem permissions or read-only mount'
    end
  end

  def unmount_device
    puts 'Unmount sdcard'

    # Use udisksctl to unmount the device
    umount_result = `udisksctl unmount -b #{@device}`
    if $?.success?
      puts "Successfully unmounted #{@device}"
    else
      puts "Unmount failed: #{umount_result.strip}"
    end
  end

  def run_callback
    callback_file = "#{File.dirname File.absolute_path(__FILE__)}/post_backup.sh"
    system(callback_file) if File.exist?(callback_file)
  end

  private

  def rsync_copy(source, destination)
    # Ensure destination directory exists
    FileUtils.mkdir_p(destination) unless Dir.exist?(destination)

    # Use rsync to copy files, preserving timestamps and only copying changed files
    cmd = "rsync -ah --update --delete '#{source}/' '#{destination}/'"

    puts "Running rsync: #{cmd}"
    success = system(cmd)

    raise "rsync failed with exit code #{$?.exitstatus}" unless success

    puts 'rsync completed successfully'
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
    end
  rescue Interrupt
    puts 'Stopping CPAPShare...'
  end
end
