require 'cloud_controller/blobstore/fingerprints_collection'
require 'cloud_controller/packager/local_bits_packer'
require 'shellwords'

class AppBitsPackage < CloudController::Packager::LocalBitsPacker
  class PackageNotFound < StandardError; end
  class ZipSizeExceeded < StandardError; end
  class InvalidZip < StandardError; end

  def create(app, uploaded_tmp_compressed_path, fingerprints_in_app_cache)
    app.package_hash = send_package_to_blobstore(app.guid, uploaded_tmp_compressed_path, fingerprints_in_app_cache)
    app.save
  ensure
    FileUtils.rm_f(uploaded_tmp_compressed_path) if uploaded_tmp_compressed_path
  end

  def create_package_in_blobstore(package_guid, package_path)
    return unless package_path

    package = VCAP::CloudController::PackageModel.find(guid: package_guid)
    raise PackageNotFound if package.nil?

    uploaded_package_zip = package_path

    begin
      raise InvalidZip.new('The zip provided was not valid') unless valid_zip?(package_path)
      raise ZipSizeExceeded if max_package_size && package_size(package_path) > max_package_size

      Dir.mktmpdir('local_bits_packer', tmp_dir) do |root_path|
        app_package_zip = File.join(root_path, 'copied_app_package.zip')
        app_packager = AppPackager.new(app_package_zip)

        if package_zip_exists?(uploaded_package_zip)
          FileUtils.cp(uploaded_package_zip, app_package_zip)
        end

        app_packager.fix_subdir_permissions

        package_blobstore.cp_to_blobstore(app_package_zip, package_guid)

        package.db.transaction do
          package.lock!
          package.package_hash = Digester.new.digest_path(app_package_zip)
          package.state = VCAP::CloudController::PackageModel::READY_STATE
          package.save
        end
      end

      VCAP::CloudController::BitsExpiration.new.expire_packages!(package.app)
    rescue => e
      package.db.transaction do
        package.lock!
        package.state = VCAP::CloudController::PackageModel::FAILED_STATE
        package.error = e.message
        package.save
      end
      raise e
    end
  ensure
    FileUtils.rm_f(package_path) if package_path
  end

  private

  def valid_zip?(package_path)
    command = "unzip -l #{Shellwords.escape(package_path)}"
    r, w = IO.pipe
    pid = Process.spawn(command, out: w, err: [:child, :out])
    w.close
    Process.wait2(pid)
    output = r.read
    r.close
    !output.split("\n").last.match(/^\s*(\d+)/).nil?
  end

  def package_size(package_path)
    zip_info = `unzip -l #{Shellwords.escape(package_path)}`
    zip_info.split("\n").last.match(/^\s*(\d+)/)[1].to_i
  end
  
  def tmp_dir
    @tmp_dir ||= VCAP::CloudController::Config.config[:directories][:tmpdir]
  end

  def package_blobstore
    @package_blobstore ||= CloudController::DependencyLocator.instance.package_blobstore
  end

  def global_app_bits_cache
    @global_app_bits_cache ||= CloudController::DependencyLocator.instance.global_app_bits_cache
  end

  def max_package_size
    @max_package_size ||= VCAP::CloudController::Config.config[:packages][:max_package_size] || 512 * 1024 * 1024
  end
end
