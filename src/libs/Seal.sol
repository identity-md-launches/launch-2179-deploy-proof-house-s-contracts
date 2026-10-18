// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Encoding} from "./Encoding.sol";

/// @notice The ARTIFACTS seal: the RULES.md R8 frame (sheet, double border, menu bar, status bar) with no dots, and a
/// mark in its empty middle that says what it is: a closed lock and SEALED while the art is encrypted, an open lock and
/// REVEALED for THE SOURCE once its owner reveals it. The frame is byte-identical to the frame group of the reference
/// `framed-*.svg` files; the mark follows it.
library Seal {
    string internal constant HEAD =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1080 1080" width="1080" height="1080"><rect width="1080" height="1080" fill="#ffffff"/>';
    string internal constant FRAME_OPEN =
        '<g fill="#1a1a1a" font-family="Menlo, ui-monospace, monospace" dominant-baseline="middle" letter-spacing="0.5"><rect x="200" y="220" width="680" height="640" fill="none" stroke="#1a1a1a" stroke-width="1.3"/><rect x="203.2" y="223.2" width="673.6" height="633.6" fill="none" stroke="#1a1a1a" stroke-width="1.3"/>';

    /// @dev A closed lock and SEALED, in grey: the art is there, encrypted, for its owner alone.
    string internal constant SEALED_MARK =
        '<g fill="none" stroke="#a8a8a2" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"><rect x="510" y="508" width="60" height="40" rx="8.8"/><path d="M524 508v-12a16 16 0 0 1 32 0v12"/></g><circle cx="540" cy="527.2" r="5.5" fill="#a8a8a2"/><text x="540" y="590" fill="#8f8f89" font-family="Menlo, ui-monospace, monospace" font-size="13" letter-spacing="6" text-anchor="middle" dominant-baseline="middle">SEALED</text>';
    /// @dev An open lock and REVEALED, in ink: THE SOURCE is public; its animation draws it.
    string internal constant REVEALED_MARK =
        '<g fill="none" stroke="#1a1a1a" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"><rect x="510" y="508" width="60" height="40" rx="8.8"/><path d="M524 508v-20a16 16 0 0 1 32 0v4"/></g><circle cx="540" cy="527.2" r="5.5" fill="#1a1a1a"/><text x="540" y="590" fill="#1a1a1a" font-family="Menlo, ui-monospace, monospace" font-size="13" letter-spacing="6" text-anchor="middle" dominant-baseline="middle">REVEALED</text><text x="540" y="616" fill="#6b6b66" font-family="Menlo, ui-monospace, monospace" font-size="11" letter-spacing="3" text-anchor="middle" dominant-baseline="middle">OPEN TO VIEW</text>';

    function text(string memory x, string memory y, string memory anchor, string memory str)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '<text x="',
            x,
            '" y="',
            y,
            '" font-size="12.5" text-anchor="',
            anchor,
            '" xml:space="preserve">',
            str,
            "</text>"
        );
    }

    function line(string memory y) internal pure returns (string memory) {
        return
            string.concat('<line x1="203.2" y1="', y, '" x2="876.8" y2="', y, '" stroke="#1a1a1a" stroke-width="1.2"/>');
    }

    /// @param title menu-bar title (right)
    /// @param statusLeft status-bar left text
    /// @param statusRight status-bar right text
    /// @param master THE SOURCE variant (Reveal menu, doubled dividers)
    /// @param mark what goes in the frame's middle: SEALED_MARK or REVEALED_MARK
    function render(
        string memory title,
        string memory statusLeft,
        string memory statusRight,
        bool master,
        string memory mark
    ) internal pure returns (string memory) {
        string memory menu = master ? "File   View   Reveal" : "File   View   Run";
        string memory top = string.concat(
            HEAD, FRAME_OPEN, text("218.0", "250.0", "start", menu), text("862.0", "250.0", "end", title)
        );
        string memory lines = master
            ? string.concat(line("263.0"), line("266.0"), line("814.0"), line("817.0"))
            : string.concat(line("266.0"), line("814.0"));
        return string.concat(
            top,
            lines,
            text("218.0", "833.0", "start", statusLeft),
            text("862.0", "833.0", "end", statusRight),
            "</g>",
            mark,
            "</svg>"
        );
    }

    /// @dev Edition seal: title / "PALETTE  ·  kC  ·  DIRECTION" / "No. nnn", the edition's number (R8; its real seed is
    /// 256 bits and never printed).
    function edition(
        string memory title,
        string memory palette,
        uint8 colourCount,
        string memory direction,
        uint256 pieceId
    ) internal pure returns (string memory) {
        string memory statusLeft = string.concat(
            palette, unicode"  ·  ", Encoding.toString(colourCount), unicode"C  ·  ", direction
        );
        return render(title, statusLeft, string.concat("No. ", Encoding.pad3(pieceId)), false, SEALED_MARK);
    }

    /// @dev THE SOURCE seal (R9 frame), sealed.
    function source() internal pure returns (string memory) {
        return render(unicode"ARTIFACTS  ◆  MASTER", "THE SOURCE", unicode"FIDELITY · MAX · 1/1", true, SEALED_MARK);
    }

    /// @dev THE SOURCE once revealed: the same frame, marked REVEALED. The art itself is the animation, drawn live by
    /// the renderer stored on-chain; a still image can't run it.
    function sourceRevealed() internal pure returns (string memory) {
        return render(unicode"ARTIFACTS  ◆  MASTER", "THE SOURCE", unicode"FIDELITY · MAX · 1/1", true, REVEALED_MARK);
    }
}
