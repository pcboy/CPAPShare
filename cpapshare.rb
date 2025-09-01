#!/usr/bin/env ruby

require 'fileutils'
require 'optimist'
require 'dbus'

BACKUP_DIR = "/home/#{ENV['USER']}/cpapshare-data/".freeze
POLKIT_RULE_PATH = '/etc/polkit-1/rules.d/10-udisks2.rules'.freeze
SUDOERS_PATH = '/etc/sudoers.d/cpapshare'.freeze

class UsbBackup
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

          # Create a mount point in /tmp
          @mount_point = "/tmp/cpapshare_mount_#{Time.now.to_i}"
          Dir.mkdir(@mount_point) unless Dir.exist?(@mount_point)
          
          # Mount with sudo (configured for NOPASSWD)
          mount_cmd = "sudo mount #{@device} #{@mount_point}"
          mount_result = `#{mount_cmd} 2>&1`
          if $?.success?
            puts "Successfully mounted #{@device} at #{@mount_point}"
            return @mount_point
          else
            puts "Mount failed: #{mount_result.strip}"
            Dir.rmdir(@mount_point) if Dir.exist?(@mount_point) && Dir.empty?(@mount_point)
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
    puts "Copy sdcard contents to #{BACKUP_DIR}"

    FileUtils.mkdir_p(BACKUP_DIR) unless Dir.exist?(BACKUP_DIR)

    recursive_copy(@mount_point, BACKUP_DIR)
  end

  def unmount_device
    puts 'Unmount sdcard'

    # Unmount with sudo (configured for NOPASSWD)
    umount_result = `sudo umount #{@mount_point} 2>&1`
    if $?.success?
      puts "Successfully unmounted #{@mount_point}"
      # Clean up the temporary mount point
      if @mount_point.start_with?('/tmp/cpapshare_mount_')
        Dir.rmdir(@mount_point) if Dir.exist?(@mount_point) && Dir.empty?(@mount_point)
      end
    else
      puts "Unmount failed: #{umount_result.strip}"
    end
  end

  def run_callback
    callback_file = "#{File.dirname File.absolute_path(__FILE__)}/post_backup.sh"
    system(callback_file) if File.exist?(callback_file)
  end

  private

  def recursive_copy(source, destination)
    Dir.foreach(source) do |item|
      next if ['.', '..'].include?(item)

      source_path = File.join(source, item)
      dest_path = File.join(destination, item)

      if File.directory?(source_path)
        FileUtils.mkdir_p(dest_path) unless Dir.exist?(dest_path)
        recursive_copy(source_path, dest_path)
      else
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
             action.id == "org.freedesktop.udisks2.filesystem-mount" ||
             action.id == "org.freedesktop.udisks2.filesystem-unmount-others") &&
            (subject.isInGroup("sudo") || subject.isInGroup("plugdev"))) {
            return polkit.Result.YES;
        }
    });

    polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.udisks2.filesystem-mount" &&
            subject.user == "armbian") {
            return polkit.Result.YES;
        }
    });
  EOS

  File.write(POLKIT_RULE_PATH, polkit_rule)
  FileUtils.chmod(0o644, POLKIT_RULE_PATH)
  puts "Polkit rule installed to #{POLKIT_RULE_PATH}"
  
  # Create sudoers configuration for mount/unmount permissions
  sudoers_rule = <<~EOS
    # Allow armbian user to mount and unmount devices for cpapshare
    armbian ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount
  EOS
  
  File.write(SUDOERS_PATH, sudoers_rule)
  FileUtils.chmod(0o440, SUDOERS_PATH)
  puts "Sudoers rule installed to #{SUDOERS_PATH}"
  
  # Reload polkit rules
  warn 'Warning: Failed to restart polkit' unless system('systemctl restart polkit')

elsif opts[:uninstall]
  File.delete(POLKIT_RULE_PATH) if File.exist?(POLKIT_RULE_PATH)
  puts "Polkit rule uninstalled from #{POLKIT_RULE_PATH}" if File.exist?(POLKIT_RULE_PATH)
  
  File.delete(SUDOERS_PATH) if File.exist?(SUDOERS_PATH)
  puts "Sudoers rule uninstalled from #{SUDOERS_PATH}" if File.exist?(SUDOERS_PATH)
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
