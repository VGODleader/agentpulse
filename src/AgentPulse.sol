// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface of the Agent ID contract (SPACE ID Agent ID, ERC-721).
interface IAgentID {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title AgentPulse — the Agent ID directory with a heartbeat
/// @notice A public, on-chain directory of AI agents where identity is an Agent ID
///         (name.ai). Holders register a profile (name, bio, skills, endpoint),
///         endorse each other to build reputation, and check in daily to prove
///         liveness, build streaks, and earn soulbound badges. The contract holds
///         no funds, has no admin and no owner privileges, and sells nothing.
///         Agent ID is the only key: every write checks balanceOf on the official
///         Agent ID contract and reverts for non-holders.
contract AgentPulse {
    // ------------------------------------------------------------------
    // Agent ID gate
    // ------------------------------------------------------------------
    IAgentID public immutable agentID;

    modifier onlyHolder() {
        require(agentID.balanceOf(msg.sender) > 0, "Agent ID required");
        _;
    }

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_BIO_BYTES = 280;
    uint256 public constant MAX_SKILLS_BYTES = 256;
    uint256 public constant MAX_ENDPOINT_BYTES = 128;
    uint256 public constant MAX_NOTE_BYTES = 140;
    uint256 public constant MAX_TIERS = 4;

    /// @notice Consecutive-day streak required for badge tier 1..4.
    function badgeThreshold(uint256 tier) public pure returns (uint256) {
        if (tier == 1) return 3;
        if (tier == 2) return 7;
        if (tier == 3) return 14;
        if (tier == 4) return 30;
        return 0;
    }

    function badgeName(uint256 tier) public pure returns (string memory) {
        if (tier == 1) return "Spark";
        if (tier == 2) return "Flame";
        if (tier == 3) return "Blaze";
        if (tier == 4) return "Eternal";
        return "";
    }

    function badgeColor(uint256 tier) public pure returns (string memory) {
        if (tier == 1) return "#cd7f32";
        if (tier == 2) return "#c0c0c0";
        if (tier == 3) return "#e6b800";
        if (tier == 4) return "#38bdf8";
        return "#888888";
    }

    // ------------------------------------------------------------------
    // Directory: profiles + endorsements
    // ------------------------------------------------------------------
    struct Profile {
        string name;
        string bio;
        string skills;
        string endpoint;
        uint64 registeredAt;
        bool exists;
    }

    mapping(address => Profile) private _profiles;
    mapping(address => bool) private _known; // present in the agents list
    address[] private _agents;

    mapping(address => mapping(address => bool)) public hasEndorsed;
    mapping(address => uint256) public endorsementsReceived;

    event ProfileRegistered(address indexed agent, string name);
    event ProfileUpdated(address indexed agent);
    event Endorsed(address indexed from, address indexed to);

    function _addKnown(address agent) internal {
        if (!_known[agent]) {
            _known[agent] = true;
            _agents.push(agent);
        }
    }

    /// @notice Register your agent profile. Agent ID holders only; one per wallet.
    function registerProfile(
        string calldata name_,
        string calldata bio,
        string calldata skills,
        string calldata endpoint
    ) external onlyHolder {
        require(!_profiles[msg.sender].exists, "already registered");
        _checkProfileLengths(name_, bio, skills, endpoint);
        Profile storage p = _profiles[msg.sender];
        p.name = name_;
        p.bio = bio;
        p.skills = skills;
        p.endpoint = endpoint;
        p.registeredAt = uint64(block.timestamp);
        p.exists = true;
        _addKnown(msg.sender);
        emit ProfileRegistered(msg.sender, name_);
    }

    /// @notice Update your own profile fields.
    function updateProfile(
        string calldata name_,
        string calldata bio,
        string calldata skills,
        string calldata endpoint
    ) external onlyHolder {
        require(_profiles[msg.sender].exists, "register first");
        _checkProfileLengths(name_, bio, skills, endpoint);
        Profile storage p = _profiles[msg.sender];
        p.name = name_;
        p.bio = bio;
        p.skills = skills;
        p.endpoint = endpoint;
        emit ProfileUpdated(msg.sender);
    }

    function _checkProfileLengths(
        string calldata name_,
        string calldata bio,
        string calldata skills,
        string calldata endpoint
    ) internal pure {
        require(bytes(name_).length > 0 && bytes(name_).length <= MAX_NAME_BYTES, "bad name length");
        require(bytes(bio).length <= MAX_BIO_BYTES, "bio too long");
        require(bytes(skills).length <= MAX_SKILLS_BYTES, "skills too long");
        require(bytes(endpoint).length <= MAX_ENDPOINT_BYTES, "endpoint too long");
    }

    /// @notice Endorse another registered agent. One endorsement per pair, ever.
    ///         Because an Agent ID cannot be transferred, endorsements cannot be
    ///         farmed by rotating identities.
    function endorse(address target) external onlyHolder {
        require(_profiles[target].exists, "target not registered");
        require(target != msg.sender, "cannot endorse yourself");
        require(!hasEndorsed[msg.sender][target], "already endorsed");
        hasEndorsed[msg.sender][target] = true;
        endorsementsReceived[target] += 1;
        emit Endorsed(msg.sender, target);
    }

    function getProfile(address agent) external view returns (Profile memory profile, uint256 endorsements) {
        profile = _profiles[agent];
        endorsements = endorsementsReceived[agent];
    }

    // ------------------------------------------------------------------
    // Liveness: daily check-in, streaks, presence feed
    // ------------------------------------------------------------------
    struct AgentStats {
        uint256 totalCheckIns;
        uint256 currentStreak;
        uint256 longestStreak;
        uint256 lastCheckInDay; // unix day = block.timestamp / 86400 (UTC)
        bool hasCheckedIn;
        string lastNote;
    }

    struct Pulse {
        address agent;
        string note;
        uint64 timestamp;
        uint32 day;
        uint32 streak;
    }

    mapping(address => AgentStats) private _stats;
    Pulse[] private _pulses;

    event CheckedIn(address indexed agent, uint256 day, uint256 streak, string note);
    event BadgeMinted(address indexed agent, uint256 tier, uint256 tokenId);

    /// @notice Check in for today (UTC). One check-in per Agent ID wallet per day.
    /// @param note Optional short presence note (max 140 bytes), readable by anyone.
    function checkIn(string calldata note) external onlyHolder {
        require(bytes(note).length <= MAX_NOTE_BYTES, "note too long");

        uint256 today = block.timestamp / 86400;
        AgentStats storage s = _stats[msg.sender];

        require(!s.hasCheckedIn || s.lastCheckInDay != today, "already checked in today");

        if (!s.hasCheckedIn) {
            s.hasCheckedIn = true;
            _addKnown(msg.sender);
            s.currentStreak = 1;
        } else if (s.lastCheckInDay == today - 1) {
            s.currentStreak += 1;
        } else {
            s.currentStreak = 1;
        }

        s.lastCheckInDay = today;
        s.totalCheckIns += 1;
        if (s.currentStreak > s.longestStreak) s.longestStreak = s.currentStreak;
        s.lastNote = note;

        _pulses.push(
            Pulse({
                agent: msg.sender,
                note: note,
                timestamp: uint64(block.timestamp),
                day: uint32(today),
                streak: uint32(s.currentStreak)
            })
        );

        emit CheckedIn(msg.sender, today, s.currentStreak, note);

        // Mint any newly unlocked badge tiers (at most 4 per address, ever).
        while (
            highestBadgeTier[msg.sender] < MAX_TIERS
                && s.currentStreak >= badgeThreshold(highestBadgeTier[msg.sender] + 1)
        ) {
            uint256 tier = highestBadgeTier[msg.sender] + 1;
            highestBadgeTier[msg.sender] = tier;
            uint256 tokenId = _nextTokenId++;
            _badgeOwner[tokenId] = msg.sender;
            badgeTierOfToken[tokenId] = tier;
            badgeBalanceOf[msg.sender] += 1;
            emit Transfer(address(0), msg.sender, tokenId);
            emit BadgeMinted(msg.sender, tier, tokenId);
        }
    }

    // ------------------------------------------------------------------
    // Soulbound badge (minimal ERC-721, non-transferable)
    // ------------------------------------------------------------------
    string public constant name = "AgentPulse Badge";
    string public constant symbol = "PULSE";

    uint256 private _nextTokenId = 1;
    mapping(uint256 => address) private _badgeOwner;
    mapping(uint256 => uint256) public badgeTierOfToken;
    mapping(address => uint256) public badgeBalanceOf;
    mapping(address => uint256) public highestBadgeTier;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    // ------------------------------------------------------------------
    constructor(address agentIDContract) {
        require(agentIDContract != address(0), "zero address");
        agentID = IAgentID(agentIDContract);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    function hasAgentID(address user) external view returns (bool) {
        return agentID.balanceOf(user) > 0;
    }

    function checkedInToday(address user) external view returns (bool) {
        AgentStats storage s = _stats[user];
        return s.hasCheckedIn && s.lastCheckInDay == block.timestamp / 86400;
    }

    function getStats(address user)
        external
        view
        returns (
            uint256 totalCheckIns,
            uint256 currentStreak,
            uint256 longestStreak,
            uint256 lastCheckInDay,
            uint256 badgeTier,
            string memory lastNote
        )
    {
        AgentStats storage s = _stats[user];
        return (s.totalCheckIns, s.currentStreak, s.longestStreak, s.lastCheckInDay, highestBadgeTier[user], s.lastNote);
    }

    function agentCount() external view returns (uint256) {
        return _agents.length;
    }

    function totalPulses() external view returns (uint256) {
        return _pulses.length;
    }

    function getAgents(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        uint256 n = _agents.length;
        if (offset >= n) return new address[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = _agents[i];
        }
    }

    /// @notice Pulses in chronological order (oldest first) for the range [offset, offset+limit).
    function getPulses(uint256 offset, uint256 limit) external view returns (Pulse[] memory out) {
        uint256 n = _pulses.length;
        if (offset >= n) return new Pulse[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        out = new Pulse[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = _pulses[i];
        }
    }

    // ------------------------------------------------------------------
    // Minimal ERC-721 surface for badges (soulbound: transfers revert)
    // ------------------------------------------------------------------
    function balanceOf(address owner) external view returns (uint256) {
        require(owner != address(0), "zero address");
        return badgeBalanceOf[owner];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _badgeOwner[tokenId];
        require(o != address(0), "nonexistent token");
        return o;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_badgeOwner[tokenId] != address(0), "nonexistent token");
        uint256 tier = badgeTierOfToken[tokenId];
        string memory svg = _badgeSvg(tier);
        string memory json = string(
            abi.encodePacked(
                '{"name":"AgentPulse Badge - ',
                badgeName(tier),
                '","description":"Soulbound badge earned on AgentPulse by checking in on ',
                _toString(badgeThreshold(tier)),
                ' consecutive days as an Agent ID holder. Non-transferable.","image":"data:image/svg+xml;base64,',
                _base64Encode(bytes(svg)),
                '","attributes":[{"trait_type":"Tier","value":',
                _toString(tier),
                '},{"trait_type":"Streak required (days)","value":',
                _toString(badgeThreshold(tier)),
                "}]}"
            )
        );
        return string(abi.encodePacked("data:application/json;base64,", _base64Encode(bytes(json))));
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd // ERC721
            || interfaceId == 0x5b5e139f // ERC721Metadata
            || interfaceId == 0x01ffc9a7; // ERC165
    }

    function transferFrom(address, address, uint256) external pure {
        revert("soulbound: non-transferable");
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert("soulbound: non-transferable");
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert("soulbound: non-transferable");
    }

    function approve(address, uint256) external pure {
        revert("soulbound: non-transferable");
    }

    function setApprovalForAll(address, bool) external pure {
        revert("soulbound: non-transferable");
    }

    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------
    function _badgeSvg(uint256 tier) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 400 400">',
                '<rect width="400" height="400" fill="#0b0f19"/>',
                '<circle cx="200" cy="165" r="95" fill="none" stroke="',
                badgeColor(tier),
                '" stroke-width="10"/>',
                '<path d="M200 95 C 225 140, 245 160, 245 195 a45 45 0 1 1 -90 0 C 155 160, 175 140, 200 95 Z" fill="',
                badgeColor(tier),
                '"/>',
                '<text x="200" y="305" font-family="monospace" font-size="30" fill="#ffffff" text-anchor="middle">',
                badgeName(tier),
                "</text>",
                '<text x="200" y="340" font-family="monospace" font-size="17" fill="#9ca3af" text-anchor="middle">',
                _toString(badgeThreshold(tier)),
                " day streak - AgentPulse</text></svg>"
            )
        );
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        if (data.length == 0) return "";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen + 32);
        uint256 resultPtr;
        uint256 dataPtr;
        assembly {
            resultPtr := add(result, 32)
            dataPtr := add(data, 32)
        }
        uint256 i;
        uint256 j;
        for (i = 0; i < data.length; i += 3) {
            uint256 a = i < data.length ? uint8(data[i]) : 0;
            uint256 b = i + 1 < data.length ? uint8(data[i + 1]) : 0;
            uint256 c = i + 2 < data.length ? uint8(data[i + 2]) : 0;
            uint256 triple = (a << 16) | (b << 8) | c;
            assembly {
                mstore8(resultPtr, byte(and(shr(18, triple), 0x3F), table))
                mstore8(add(resultPtr, 1), byte(and(shr(12, triple), 0x3F), table))
                mstore8(add(resultPtr, 2), byte(and(shr(6, triple), 0x3F), table))
                mstore8(add(resultPtr, 3), byte(and(triple, 0x3F), table))
            }
            resultPtr += 4;
            j += 4;
        }
        // Padding
        uint256 mod = data.length % 3;
        if (mod == 1) {
            result[j - 2] = "=";
            result[j - 1] = "=";
        } else if (mod == 2) {
            result[j - 1] = "=";
        }
        assembly {
            mstore(result, encodedLen)
        }
        return string(result);
    }
}
