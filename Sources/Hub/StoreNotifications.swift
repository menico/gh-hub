import Foundation
import HubKit

/// The Notifications section: GitHub's inbox for every account.
extension Store {
    /// Notifications for the accounts in view, unread first, newest first.
    var visibleNotifications: [GHNotification] {
        notifications.filter { shown([$0.accountID], in: activeScope) }
            .sorted { ($0.unread ? 1 : 0, $0.updatedAt) > ($1.unread ? 1 : 0, $1.updatedAt) }
    }

    var unreadNotificationCount: Int { visibleNotifications.filter(\.unread).count }

    func notification(_ id: String) -> GHNotification? { notifications.first { $0.id == id } }

    func refreshNotifications() async {
        let targets = accounts.compactMap { state in client(state.id).map { (state.id, $0) } }
        // One account after another: a handful of requests, mostly 304s.
        var fetched: [String: Result<[GHNotification], Error>] = [:]
        for (id, client) in targets {
            do { fetched[id] = .success(try await client.notifications()) } catch { fetched[id] = .failure(error) }
        }
        var merged: [GHNotification] = []
        for (id, _) in targets {
            switch fetched[id] {
            case .success(let fresh):
                notificationsError[id] = nil
                let ids = Set(fresh.map(\.id))
                // Read here this session and no longer unread on GitHub: keep showing them, dimmed.
                merged += fresh + notifications.filter { $0.accountID == id && !$0.unread && !ids.contains($0.id) }
            case .failure(let error):
                notificationsError[id] = error.localizedDescription
                merged += notifications.filter { $0.accountID == id }
            case nil:
                break
            }
        }
        notifications = merged
    }

    /// Banners for threads that are new or have new activity since the last refresh.
    func announceNotifications() {
        let unread = notifications.filter { $0.unread && shown([$0.accountID], in: nil) }
        let keys = Set(unread.map { "\($0.id)@\($0.updatedAt.timeIntervalSince1970)" })
        if let seen = seenNotificationKeys {
            let fresh = unread.filter { $0.deservesBanner && !seen.contains("\($0.id)@\($0.updatedAt.timeIntervalSince1970)") }
            // A burst (back from sleep) is one banner, not twenty.
            if fresh.count > 3 {
                notify(title: "\(fresh.count) new notifications", body: Set(fresh.map(\.repo)).sorted().prefix(3).joined(separator: ", "),
                       target: "pane:notifications")
            } else {
                for n in fresh {
                    notify(title: "\(n.reasonLabel) · \(n.repo)", body: n.title, target: "notification:\(n.id)")
                }
            }
            seenNotificationKeys = seen.union(keys)
        } else {
            seenNotificationKeys = keys
        }
    }

    private func setUnread(_ id: String, _ unread: Bool) {
        if let index = notifications.firstIndex(where: { $0.id == id }) { notifications[index].unread = unread }
    }

    func markRead(_ n: GHNotification) {
        guard n.unread, let client = client(n.accountID) else { return }
        setUnread(n.id, false)
        Task {
            do { try await client.markRead(n) } catch {
                setUnread(n.id, true)
                show(.failure, "Couldn't mark it read: \(error.localizedDescription)")
            }
        }
    }

    /// Out of the inbox here and on github.com.
    func markDone(_ n: GHNotification) {
        guard let client = client(n.accountID) else { return }
        let before = notifications
        notifications.removeAll { $0.id == n.id }
        Task {
            do { try await client.markDone(n) } catch {
                notifications = before
                show(.failure, "Couldn't mark it done: \(error.localizedDescription)")
            }
        }
    }

    /// Every unread notification of the accounts in view.
    func markAllRead() {
        let unread = visibleNotifications.filter(\.unread)
        let accountIDs = Set(unread.map(\.accountID))
        for n in unread { setUnread(n.id, false) }
        Task {
            for id in accountIDs {
                guard let client = client(id) else { continue }
                do { try await client.markAllNotificationsRead() } catch {
                    for n in unread where n.accountID == id { setUnread(n.id, true) }
                    show(.failure, "Couldn't mark \(name(id))'s notifications read: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The pull request or issue a notification is about, as the account that got it.
    func subject(of n: GHNotification) async throws -> Selection? {
        guard let number = n.number, let client = client(n.accountID) else { return nil }
        if n.isPullRequest {
            if let pr = (reviewRequests + reviewedPulls + myPulls).first(where: { $0.repo.lowercased() == n.repo.lowercased() && $0.number == number }) {
                return .pr(pr)
            }
            let me = account(n.accountID)?.account.login.lowercased()
            var pr = try await client.pullRequest(repo: n.repo, number: number, lane: .reviewRequested)
            if pr.author.lowercased() == me { pr = try await client.pullRequest(repo: n.repo, number: number, lane: .mine) }
            return .pr(pr)
        }
        if n.isIssue {
            if let issue = issues.first(where: { $0.repo.lowercased() == n.repo.lowercased() && $0.number == number }) { return .issue(issue) }
            return .issue(try await client.issue(repo: n.repo, number: number))
        }
        return nil
    }
}
