import Foundation

/// Official product and source links shared by app surfaces that send users
/// outside MacSweep. Keep these centralized so a repository or domain move
/// cannot leave About and share views pointing at different destinations.
public enum MacSweepLinks {
    public static let website = URL(string: "https://macsweep.dev")!
    public static let repository = URL(string: "https://github.com/VincentShipsIt/macsweep.dev")!
    public static let websiteDisplayName = "macsweep.dev"
}
