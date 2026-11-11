// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/// @dev Shared helpers for deployment outputs: `KEY=value` lines in `.env`, or
///      JSON files under `deployments/` when `DEPLOYMENT_OUTPUT` is set.
abstract contract EnvFile is Script {
    /// @dev Returns the `DEPLOYMENT_OUTPUT` path prefix, or "" when unset or empty.
    ///      A nonempty prefix must stay inside `deployments/`.
    function _deploymentOutput() internal view returns (string memory prefix) {
        prefix = vm.envOr("DEPLOYMENT_OUTPUT", string(""));
        bytes memory data = bytes(prefix);
        if (data.length == 0) return prefix;

        bytes memory dir = bytes("deployments/");
        require(data.length > dir.length, "DEPLOYMENT_OUTPUT must be under deployments/");
        for (uint256 i = 0; i < dir.length; i++) {
            require(data[i] == dir[i], "DEPLOYMENT_OUTPUT must be under deployments/");
        }
        for (uint256 i = 0; i + 1 < data.length; i++) {
            require(data[i] != "." || data[i + 1] != ".", "DEPLOYMENT_OUTPUT must not contain ..");
        }
    }

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
