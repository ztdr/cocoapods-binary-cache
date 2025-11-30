module PodPrebuild
  class DependenciesGraphCacheValidator < AccumulatedCacheValidator
    def initialize(options)
      super(options)
      @ignored_pods = options[:ignored_pods] || Set.new
    end

    def validate(accumulated)
      return accumulated if library_evolution_supported? || @pod_lockfile.nil?

      dependencies_graph = DependenciesGraph.new(lockfile: @pod_lockfile.lockfile, invert_edge: true)
      # 获取所有未命中的pods，但排除Local Pods（dev pods）
      # 因为Local Pods的未命中不应该导致它们的客户端被标记为未命中
      # 即使dev_pods_enabled为true，Local Pods的未命中也不应该影响它们的客户端
      missed_pods = accumulated.discard(@ignored_pods).missed.to_a
      # 排除所有Local Pods的未命中项，无论dev_pods_enabled是否为true
      missed_pods = missed_pods.reject { |pod| @pod_lockfile.dev_pods.keys.include?(pod.split("/")[0]) }
      
      # 只考虑父pod级别的未命中，而不是subspec级别的未命中
      # 将subspec转换为父pod名称，并去重
      missed_root_pods = missed_pods.map { |pod| pod.split("/")[0] }.uniq
      
      # 过滤掉在hit列表中的父pods，或者有任何subspec命中的父pods
      # 如果父pod在hit列表中，说明它命中了，不应该传播未命中
      # 如果父pod有任何subspec命中，说明它至少部分命中了，不应该传播未命中
      # 这可以防止因为某些subspec未命中而导致依赖父pod的其他pods被错误标记为未命中
      missed_root_pods = missed_root_pods.reject do |root_pod|
        # 如果父pod本身在hit列表中，不应该传播
        next true if accumulated.hit.include?(root_pod)
        
        # 如果父pod有任何subspec命中，不应该传播
        # 检查hit列表中是否有该父pod的任何subspec
        accumulated.hit.any? { |hit_pod| hit_pod.split("/")[0] == root_pod }
      end
      
      clients = dependencies_graph.get_clients(missed_root_pods)
      unless PodPrebuild.config.dev_pods_enabled?
        clients = clients.reject { |client| @pod_lockfile.dev_pods.keys.include?(client) }
      end

      missed = clients.map { |client| [client, "Dependencies were missed"] }.to_h
      accumulated.merge(PodPrebuild::CacheValidationResult.new(missed, Set.new))
    end

    def library_evolution_supported?
      false
    end
  end
end
