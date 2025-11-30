module PodPrebuild
  class BaseCacheValidator
    attr_reader :podfile, :pod_lockfile, :prebuilt_lockfile
    attr_reader :validate_prebuilt_settings, :generated_framework_path

    def initialize(options)
      @podfile = options[:podfile]
      @pod_lockfile = options[:pod_lockfile] && PodPrebuild::Lockfile.new(options[:pod_lockfile])
      @prebuilt_lockfile = options[:prebuilt_lockfile] && PodPrebuild::Lockfile.new(options[:prebuilt_lockfile])
      @validate_prebuilt_settings = options[:validate_prebuilt_settings]
      @generated_framework_path = options[:generated_framework_path]
    end

    def validate(*)
      raise NotImplementedError
    end

    def changes_of_prebuilt_lockfile_vs_podfile
      @changes_of_prebuilt_lockfile_vs_podfile ||= Pod::Installer::Analyzer::SpecsState.new(
        @prebuilt_lockfile.lockfile.detect_changes_with_podfile(@podfile)
      )
    end

    def validate_with_podfile
      changes = changes_of_prebuilt_lockfile_vs_podfile
      missed = changes.added.map { |pod| [pod, "Added from Podfile"] }.to_h
      missed.merge!(changes.changed.map { |pod| [pod, "Updated from Podfile"] }.to_h)
      PodPrebuild::CacheValidationResult.new(missed, changes.unchanged)
    end

    def validate_pods(options)
      pods = options[:pods]
      subspec_pods = options[:subspec_pods]
      prebuilt_pods = options[:prebuilt_pods]

      missed = {}
      hit = Set.new

      check_pod = lambda do |name|
        root_name = name.split("/")[0]
        version = pods[name]
        # 如果 pod 不在 Podfile.lock 中，跳过验证
        # 这可以防止检查当前 Podfile.lock 中不存在的 pods
        return true if version.nil?
        
        prebuilt_version = prebuilt_pods[name]
        result = false
        if prebuilt_version.nil?
          missed[name] = "Not available (#{version})"
        elsif prebuilt_version != version
          missed[name] = "Outdated: (prebuilt: #{prebuilt_version}) vs (#{version})"
        elsif load_metadata(root_name).blank?
          missed[name] = "Metadata not available (probably #{root_name}.zip is not in GeneratedFrameworks)"
        else
          diff = incompatible_pod(root_name)
          if diff.empty?
            hit << name
            result = true
          else
            missed[name] = "Incompatible: #{diff}"
          end
        end
        result
      end

      subspec_pods.each do |parent, children|
        # 只检查在 pods hash 中存在的 children（来自 Podfile.lock）
        # 这对 Local Pods 很重要：如果某个 subspec 不在 Podfile.lock 中，
        # 即使它出现在 subspec_pods 分组中，也不应该被检查
        existing_children = children.select { |child| pods.key?(child) }
        next if existing_children.empty?
        
        missed_children = existing_children.reject { |child| check_pod.call(child) }
        if missed_children.empty?
          # 只有当父 pod 在 Podfile.lock 中存在时，才标记为命中
          # 对于 Local Pods，父 pod 可能不在 non_dev_pods 中
          hit << parent if pods.key?(parent)
        else
          # 只有当父 pod 在 Podfile.lock 中存在时，才标记为未命中
          # 这可以防止 Local Pods 的误报
          missed[parent] = "Subspec pods were missed: #{missed_children}" if pods.key?(parent)
        end
      end

      non_subspec_pods = pods.reject { |pod| subspec_pods.include?(pod) }
      non_subspec_pods.each { |pod, _| check_pod.call(pod) }
      PodPrebuild::CacheValidationResult.new(missed, hit)
    end

    def incompatible_pod(name)
      # Pod incompatibility is a universal concept. Generally, it requires build settings compatibility.
      # For more checks, do override this function to define what it means by `incompatible`.
      incompatible_build_settings(name)
    end

    def incompatible_build_settings(name)
      settings_diff = {}
      prebuilt_build_settings = read_prebuilt_build_settings(name)
      validate_prebuilt_settings&.(name)&.each do |key, value|
        prebuilt_value = prebuilt_build_settings[key]
        unless prebuilt_value.nil? || value == prebuilt_value
          settings_diff[key] = { :current => value, :prebuilt => prebuilt_value }
        end
      end
      settings_diff
    end

    def load_metadata(name)
      @metadata_cache ||= {}
      cache = @metadata_cache[name]
      return cache unless cache.nil?

      metadata = PodPrebuild::Metadata.in_dir(generated_framework_path + name)
      @metadata_cache[name] = metadata
      metadata
    end

    def read_prebuilt_build_settings(name)
      load_metadata(name).build_settings
    end

    def read_source_hash(name)
      load_metadata(name).source_hash
    end
  end
end
