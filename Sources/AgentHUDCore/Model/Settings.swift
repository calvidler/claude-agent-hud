import Combine
import Foundation

final class Settings: ObservableObject {
    @Published var prefs: Prefs
    private var saver: AnyCancellable?

    init() {
        if let data = UserDefaults.standard.data(forKey: "prefs"),
           let decoded = try? JSONDecoder().decode(Prefs.self, from: data) {
            prefs = decoded
        } else {
            prefs = Prefs()
        }
        saver = $prefs
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { prefs in
                if let data = try? JSONEncoder().encode(prefs) {
                    UserDefaults.standard.set(data, forKey: "prefs")
                }
            }
    }
}
