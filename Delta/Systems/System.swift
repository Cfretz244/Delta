//
//  System.swift
//  Delta
//
//  Created by Riley Testut on 4/30/17.
//  Copyright © 2017 Riley Testut. All rights reserved.
//

import DeltaCore

import SNESDeltaCore
import GBADeltaCore
import GBCDeltaCore
import NESDeltaCore
import N64DeltaCore
import MelonDSDeltaCore
import GPGXDeltaCore
import GCDeltaCore

enum System: CaseIterable
{
    case nes
    case genesis
    case snes
    case n64
    case gbc
    case gba
    case ds
    case gc
    case wii

    static var registeredSystems: [System] {
        let systems = System.allCases.filter { Delta.registeredCores.keys.contains($0.gameType) }
        return systems
    }

    static var allCores: [DeltaCoreProtocol] {
        return [NES.core, SNES.core, N64.core, GBC.core, GBA.core, MelonDS.core, GPGX.core, GC.core, Wii.core]
    }
}

extension System
{
    var localizedName: String {
        switch self
        {
        case .nes: return NSLocalizedString("Nintendo", comment: "")
        case .snes: return NSLocalizedString("Super Nintendo", comment: "")
        case .n64: return NSLocalizedString("Nintendo 64", comment: "")
        case .gbc: return NSLocalizedString("Game Boy Color", comment: "")
        case .gba: return NSLocalizedString("Game Boy Advance", comment: "")
        case .ds: return NSLocalizedString("Nintendo DS", comment: "")
        case .genesis: return NSLocalizedString("Sega Genesis", comment: "")
        case .gc: return NSLocalizedString("GameCube", comment: "")
        case .wii: return NSLocalizedString("Wii", comment: "")
        }
    }

    var localizedShortName: String {
        switch self
        {
        case .nes: return NSLocalizedString("NES", comment: "")
        case .snes: return NSLocalizedString("SNES", comment: "")
        case .n64: return NSLocalizedString("N64", comment: "")
        case .gbc: return NSLocalizedString("GBC", comment: "")
        case .gba: return NSLocalizedString("GBA", comment: "")
        case .ds: return NSLocalizedString("DS", comment: "")
        case .genesis: return NSLocalizedString("Genesis (Beta)", comment: "")
        case .gc: return NSLocalizedString("GC", comment: "")
        case .wii: return NSLocalizedString("Wii", comment: "")
        }
    }
    
    var localizedDisplayName: String {
        switch self
        {
        case .nes: return NSLocalizedString("NES", comment: "")
        case .snes: return NSLocalizedString("Super Nintendo", comment: "")
        case .n64: return NSLocalizedString("Nintendo 64", comment: "")
        case .gbc: return NSLocalizedString("Game Boy Color", comment: "")
        case .gba: return NSLocalizedString("Game Boy Advance", comment: "")
        case .ds: return NSLocalizedString("Nintendo DS", comment: "")
        case .genesis: return NSLocalizedString("Sega Genesis", comment: "")
        case .gc: return NSLocalizedString("GameCube", comment: "")
        case .wii: return NSLocalizedString("Wii", comment: "")
        }
    }

    var year: Int {
        switch self
        {
        case .nes: return 1985
        case .genesis: return 1989
        case .snes: return 1990
        case .n64: return 1996
        case .gbc: return 1998
        case .gba: return 2001
        case .gc: return 2001
        case .ds: return 2004
        case .wii: return 2006
        }
    }
}

extension System
{
    var deltaCore: DeltaCoreProtocol {
        switch self
        {
        case .nes: return NES.core
        case .snes: return SNES.core
        case .n64: return N64.core
        case .gbc: return GBC.core
        case .gba: return GBA.core
        case .ds: return Settings.preferredCore(for: .ds) ?? MelonDS.core
        case .genesis: return GPGX.core
        case .gc: return GC.core
        case .wii: return Wii.core
        }
    }
    
    var gameType: DeltaCore.GameType {
        switch self
        {
        case .nes: return .nes
        case .snes: return .snes
        case .n64: return .n64
        case .gbc: return .gbc
        case .gba: return .gba
        case .ds: return .ds
        case .genesis: return .genesis
        case .gc: return .gc
        case .wii: return .wii
        }
    }
    
    init?(gameType: DeltaCore.GameType)
    {
        switch gameType
        {
        case GameType.nes: self = .nes
        case GameType.snes: self = .snes
        case GameType.n64: self = .n64
        case GameType.gbc: self = .gbc
        case GameType.gba: self = .gba
        case GameType.ds: self = .ds
        case GameType.genesis: self = .genesis
        case GameType.gc: self = .gc
        case GameType.wii: self = .wii
        default: return nil
        }
    }
}

extension DeltaCore.GameType
{
    init?(fileExtension: String)
    {
        switch fileExtension.lowercased()
        {
        case "nes": self = .nes
        case "smc", "sfc", "fig": self = .snes
        case "n64", "z64": self = .n64
        case "gbc", "gb": self = .gbc
        case "gba": self = .gba
        case "ds", "nds": self = .ds
        case "gen", "bin", "md", "smd": self = .genesis
        // GameCube and Wii disc images share extensions; anything ambiguous
        // starts as .gc and import refines it via refinedDiscGameType(forFileAt:).
        case "iso", "gcm", "gcz", "rvz", "ciso": self = .gc
        case "wbfs": self = .wii
        default: return nil
        }
    }

    // Disambiguates GameCube vs Wii disc images by content. The disc header
    // carries a platform magic word (Wii 0x5D1C9EA3 at 0x18, GC 0xC2339F3D at
    // 0x1C); RVZ/WIA containers embed a copy of that header at file offset
    // 0x58 (WIAHeader1 is 0x48 bytes, disc_header sits 0x10 into WIAHeader2).
    // Unreadable or unrecognized files keep the extension-derived type —
    // Dolphin's boot-time platform detection is authoritative anyway.
    func refinedDiscGameType(forFileAt url: URL) -> DeltaCore.GameType
    {
        guard self == .gc else { return self }

        let headerOffset: UInt64
        switch url.pathExtension.lowercased()
        {
        case "iso", "gcm": headerOffset = 0
        case "rvz": headerOffset = 0x58
        default: return self // gcz/ciso: compressed/blocked containers, GC in practice
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return self }
        defer { try? fileHandle.close() }

        guard let data = try? { try fileHandle.seek(toOffset: headerOffset); return try fileHandle.read(upToCount: 0x20) }(),
              data.count == 0x20
        else { return self }

        let wiiMagic = data.subdata(in: 0x18 ..< 0x1C).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (wiiMagic == 0x5D1C9EA3) ? .wii : self
    }
}
