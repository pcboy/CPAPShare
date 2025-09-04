require 'fileutils'
require 'tmpdir'
require 'date'
require_relative '../cpapshare'

RSpec.describe UsbBackup do
  let(:source_dir) { Dir.mktmpdir('source') }
  let(:dest_dir) { Dir.mktmpdir('dest') }
  let(:backup) { UsbBackup.new }
  let(:datalog_path) { File.join(source_dir, 'DATALOG') }

  before do
    backup.instance_variable_set(:@config, { 'copy_type' => 'dates' })
    backup.instance_variable_set(:@mount_point, source_dir)
    stub_const('UsbBackup::BACKUP_DIR', dest_dir)
  end

  after do
    FileUtils.remove_entry_secure(source_dir) if source_dir
    FileUtils.remove_entry_secure(dest_dir) if dest_dir
  end

  # Helper methods for creating test data structures
  def create_source_structure(dates = %w[20250711 20250819 20250820])
    FileUtils.mkdir_p(datalog_path)

    dates.each do |date|
      date_dir = File.join(datalog_path, date)
      FileUtils.mkdir_p(date_dir)
      File.write(File.join(date_dir, "#{date}_004707_BRP.edf"), "Data from #{date}")
    end

    create_standard_source_files
  end

  def create_standard_source_files
    File.write(File.join(source_dir, 'Identification.crc'), 'Device identification')
    File.write(File.join(source_dir, 'STR.edf'), 'STR data')
  end

  def create_previous_backup(date_range, options = {})
    backup_path = File.join(dest_dir, date_range)
    FileUtils.mkdir_p(backup_path)

    if options[:with_datalog] != false
      datalog_backup_path = File.join(backup_path, 'DATALOG')
      FileUtils.mkdir_p(datalog_backup_path)

      # Create date directories if specified
      if options[:dates]
        options[:dates].each do |date|
          date_dir = File.join(datalog_backup_path, date)
          FileUtils.mkdir_p(date_dir)

          if options[:with_files] != false
            File.write(File.join(date_dir, "#{date}_004707_BRP.edf"), "Data from #{date}")
          end
        end
      end
    end

    # Add a marker file to establish backup existence
    File.write(File.join(backup_path, 'test.txt'), 'previous backup content') if options[:with_marker]

    backup_path
  end

  def create_file_with_timestamp(file_path, content, timestamp)
    File.write(file_path, content)
    File.utime(timestamp, timestamp, file_path)
  end

  def backup_directories
    Dir.children(dest_dir).select { |entry| File.directory?(File.join(dest_dir, entry)) }.sort
  end

  def expect_file_exists_in_backup(backup_dir_name, relative_path)
    full_path = File.join(dest_dir, backup_dir_name, relative_path)
    expect(File).to exist(full_path), "Expected file to exist: #{relative_path} in backup #{backup_dir_name}"
  end

  def expect_file_not_exists_in_backup(backup_dir_name, relative_path)
    full_path = File.join(dest_dir, backup_dir_name, relative_path)
    expect(File).not_to exist(full_path), "Expected file to NOT exist: #{relative_path} in backup #{backup_dir_name}"
  end

  describe '#copy_with_dates' do
    context 'when there are no previous backups' do
      before do
        create_source_structure
      end

      it 'copies all files and creates a date range folder' do
        backup.copy_contents

        backup_dirs = backup_directories
        expect(backup_dirs.size).to eq(1)
        expect(backup_dirs.first).to eq('2025-07-11_2025-08-20')

        # Check that all files were copied correctly
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'Identification.crc')
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'STR.edf')
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'DATALOG')
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'DATALOG/20250711')
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'DATALOG/20250819')
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'DATALOG/20250820')
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'DATALOG/20250711/20250711_004707_BRP.edf')
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'DATALOG/20250819/20250819_004707_BRP.edf')
        expect_file_exists_in_backup('2025-07-11_2025-08-20', 'DATALOG/20250820/20250820_004707_BRP.edf')
      end
    end

    context 'when there are previous backups' do
      before do
        create_previous_backup('2025-07-11_2025-08-19')
        create_source_structure
      end

      it 'only copies new data and creates a folder with only new dates' do
        backup.copy_contents

        backup_dirs = backup_directories
        expect(backup_dirs).to contain_exactly('2025-07-11_2025-08-19', '2025-08-20')

        # Check that files were copied correctly to the new backup directory
        expect_file_exists_in_backup('2025-08-20', 'Identification.crc')
        expect_file_exists_in_backup('2025-08-20', 'STR.edf')
        expect_file_exists_in_backup('2025-08-20', 'DATALOG')
        expect_file_exists_in_backup('2025-08-20', 'DATALOG/20250820')
        expect_file_exists_in_backup('2025-08-20', 'DATALOG/20250820/20250820_004707_BRP.edf')
      end
    end

    context 'when there is a single previous backup day' do
      before do
        create_previous_backup('2025-08-19')
        create_source_structure
      end

      it 'only copies new data and creates a folder with only new dates' do
        backup.copy_contents

        backup_dirs = backup_directories
        expect(backup_dirs).to contain_exactly('2025-08-19', '2025-08-20')

        # Check that files were copied correctly to the new backup directory
        expect_file_exists_in_backup('2025-08-20', 'Identification.crc')
        expect_file_exists_in_backup('2025-08-20', 'STR.edf')
        expect_file_exists_in_backup('2025-08-20', 'DATALOG')
        expect_file_exists_in_backup('2025-08-20', 'DATALOG/20250820')
        expect_file_exists_in_backup('2025-08-20', 'DATALOG/20250820/20250820_004707_BRP.edf')
      end
    end

    context 'when there are previous backups and the latest date folder on sdcard contains newer data than the backup' do
      before do
        # Create previous backup with specific structure
        previous_backup_path = create_previous_backup('2025-08-19_2025-08-20',
                                                      with_marker: true,
                                                      dates: %w[20250819 20250820],
                                                      with_files: true)

        # Set up old file with specific timestamp in previous backup
        old_file_path = File.join(previous_backup_path, 'DATALOG', '20250820', '20250820_004707_BRP.edf')
        old_time = Time.new(2025, 8, 20, 10, 0, 0)
        create_file_with_timestamp(old_file_path, 'Older data from 20250820 in backup', old_time)

        # Create source structure
        create_source_structure(%w[20250819 20250820 20250821])

        # Create newer file on SD card
        newer_file_path = File.join(datalog_path, '20250820', '20250820_004707_BRP.edf')
        newer_time = Time.new(2025, 8, 20, 12, 0, 0)
        create_file_with_timestamp(newer_file_path, 'Newer data from 20250820 on SD card', newer_time)
      end

      it 'creates a backup including the date folder with newer data and the new date folder' do
        backup.copy_contents

        backup_dirs = backup_directories
        expect(backup_dirs).to contain_exactly('2025-08-19_2025-08-20', '2025-08-20_2025-08-21')

        # Check that files were copied correctly to the new backup directory
        expect_file_exists_in_backup('2025-08-20_2025-08-21', 'Identification.crc')
        expect_file_exists_in_backup('2025-08-20_2025-08-21', 'STR.edf')
        expect_file_exists_in_backup('2025-08-20_2025-08-21', 'DATALOG')
        expect_file_exists_in_backup('2025-08-20_2025-08-21', 'DATALOG/20250820')
        expect_file_exists_in_backup('2025-08-20_2025-08-21', 'DATALOG/20250820/20250820_004707_BRP.edf')
        expect_file_exists_in_backup('2025-08-20_2025-08-21', 'DATALOG/20250821')
        expect_file_exists_in_backup('2025-08-20_2025-08-21', 'DATALOG/20250821/20250821_004707_BRP.edf')

        # It should not copy the older directory that was already backed up with no changes
        expect_file_not_exists_in_backup('2025-08-20_2025-08-21', 'DATALOG/20250819')
      end
    end
  end
end
