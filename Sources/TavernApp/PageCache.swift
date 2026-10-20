import Foundation
import TavernCore

/// What pages show between visits: the last value stays on screen while a fresh one loads, so
/// opening the Dashboard doesn't flash "–" and Services doesn't start empty. Kept in memory for
/// the app's run; the container count also survives a relaunch.
extension AppModel {
    private static let containersRunningKey = "tavern.cache.containersRunning"

    /// Running containers across the agents' machines: the latest reading, else the last one
    /// from a previous run, else nil.
    var containersRunning: Int? {
        let readings = containerResults.values.compactMap { try? $0.get() }
        if !readings.isEmpty { return readings.reduce(0) { $0 + $1.filter(\.isRunning).count } }
        return UserDefaults.standard.object(forKey: Self.containersRunningKey) as? Int
    }

    /// Reads every machine's containers, unless a reading newer than `maxAge` seconds is in hand.
    /// Calls made while one is running wait for it instead of starting another.
    func refreshContainers(maxAge: TimeInterval = 0) async {
        if let at = containersRefreshedAt, Date().timeIntervalSince(at) < maxAge, !containerResults.isEmpty { return }
        if let running = containerRefresh { return await running.value }
        let hosts = DockerHost.hosts(for: roster)
        let task = Task { @MainActor in
            await withTaskGroup(of: (String, Result<[DockerContainer], DockerError>).self) { group in
                for host in hosts {
                    group.addTask {
                        do { return (host.id, .success(try await host.containers())) }
                        catch let error as DockerError { return (host.id, .failure(error)) }
                        catch { return (host.id, .failure(DockerError(message: error.localizedDescription))) }
                    }
                }
                for await (id, result) in group { self.containerResults[id] = result }
            }
            self.containersRefreshedAt = Date()
            if let count = self.containersRunning, self.containerResults.values.contains(where: { (try? $0.get()) != nil }) {
                UserDefaults.standard.set(count, forKey: Self.containersRunningKey)
            }
        }
        containerRefresh = task
        await task.value
        containerRefresh = nil
    }
}
