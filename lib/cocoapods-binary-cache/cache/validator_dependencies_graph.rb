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
      
      clients = dependencies_graph.get_clients(missed_pods)
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
