import Foundation

/// Resolves only the selected local server, then reads GPU execution counters
/// belonging to its verified processes. Remote endpoints never use this Mac's GPU.
public actor LocalBackendGPUMonitor: BackendGPUMonitoring {
    private let resolver: any BackendProcessResolving
    private let sampler: any GPUActivitySampling

    public init(
        resolver: any BackendProcessResolving = LocalBackendProcessResolver(),
        sampler: any GPUActivitySampling = IOKitGPUActivitySampler()
    ) {
        self.resolver = resolver
        self.sampler = sampler
    }

    public func sample(_ configuration: BackendConfiguration?) async -> GPUActivitySample {
        guard let configuration else {
            await reset()
            return GPUActivitySample(unavailableReason: "No backend is selected.")
        }
        let selection = await resolver.resolve(configuration)
        guard !Task.isCancelled else { return GPUActivitySample() }
        guard !selection.processes.isEmpty else {
            await sampler.reset()
            return GPUActivitySample(
                unavailableReason: selection.unavailableReason
                    ?? "No inference worker could be identified for this backend.")
        }
        return await sampler.sample(processes: selection.processes)
    }

    public func reset() async {
        await resolver.reset()
        await sampler.reset()
    }
}
