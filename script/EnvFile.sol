// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/// @dev Shared helpers for scripts that upsert `KEY=value` lines in `.env`.
abstract contract EnvFile is Script {
    function _upsertEnvAddress(
        string memory env,
        string memory key,
        address value
    ) internal view returns (string memory) {
        return _upsertEnvLine(env, key, vm.toString(value));
    }

    function _upsertEnvLine(
        string memory env,
        string memory key,
        string memory value
    ) internal pure returns (string memory) {
        bytes memory data = bytes(env);
        bytes memory keyBytes = bytes(key);
        uint256 lineStart = 0;

        for (uint256 i = 0; i <= data.length; i++) {
            if (i != data.length && data[i] != bytes1("\n")) continue;

            if (_lineStartsWithKey(data, lineStart, i, keyBytes)) {
                string memory beforeLine = _slice(data, 0, lineStart);
                string memory afterLine = _slice(data, i, data.length);
                return string.concat(beforeLine, key, "=", value, afterLine);
            }

            lineStart = i + 1;
        }

        string memory separator = data.length == 0 || data[data.length - 1] == bytes1("\n")
            ? ""
            : "\n";
        return string.concat(env, separator, key, "=", value, "\n");
    }

    function _lineStartsWithKey(
        bytes memory data,
        uint256 lineStart,
        uint256 lineEnd,
        bytes memory key
    ) internal pure returns (bool) {
        if (lineEnd <= lineStart + key.length) return false;
        if (data[lineStart] == bytes1("#")) return false;
        for (uint256 j = 0; j < key.length; j++) {
            if (data[lineStart + j] != key[j]) return false;
        }
        return data[lineStart + key.length] == bytes1("=");
    }

    function _slice(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure returns (string memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = data[i];
        }
        return string(out);
    }
}
