local ADDON, CBAB = ...

-- CBAB.Comm:Send(msgType, payload, channel)
-- CBAB.Comm:BroadcastSelf()
-- CBAB.Comm:PushAssignment()
-- CBAB.Comm:Hello()
-- CBAB.Comm:EpochTable() -> {}
--
-- Protocol (spec 8): prefix "CBAB", LibSerialize -> LibDeflate -> chunked
-- at 240 bytes with a fixed 9-char "%03d%03d%03d" (msgId, part, total)
-- header per chunk -- fixed-width so reassembly never has to search for a
-- delimiter that might collide with the encoded payload's own bytes.

local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

local COMM_PREFIX = "CBAB"
local CHUNK_SIZE = 240

local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local RawSendAddonMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
RegisterPrefix(COMM_PREFIX)

CBAB.Comm = {}

-- ============================================================
-- Name helpers
-- ============================================================

local function senderNameOnly(rawSender)
	return rawSender:match("^([^-]+)") or rawSender
end

local function senderNameRealm(rawSender)
	local name, realm = rawSender:match("^([^-]+)-?(.*)$")
	name = name or rawSender
	if not realm or realm == "" then
		realm = GetRealmName()
	end
	return name .. "-" .. realm
end

local function myNameRealm()
	return UnitName("player") .. "-" .. GetRealmName()
end

local function groupChannel()
	if IsInRaid() then
		return IsInInstance() and "INSTANCE_CHAT" or "RAID"
	elseif IsInGroup() then
		return IsInInstance() and "INSTANCE_CHAT" or "PARTY"
	end
	return nil
end

-- Reject rule (spec 8 throttle policy): only current raid/party members or
-- guildmates are trusted. Group-channel messages are already restricted to
-- group members by WoW's own delivery (a non-member literally can't send
-- on RAID/PARTY/GUILD/INSTANCE_CHAT), but WHISPER isn't, so this matters
-- specifically for whispered replies (hello replies, PUSHACK). Checked
-- uniformly for every inbound message anyway, since it's cheap.
local function isKnownSender(name)
	for _, m in pairs(CBAB.Roster:Get()) do
		if not m.isPet and m.name == name then
			return true
		end
	end
	if IsInGuild() then
		for i = 1, GetNumGuildMembers() do
			local guildName = GetGuildRosterInfo(i)
			if guildName and senderNameOnly(guildName) == name then
				return true
			end
		end
	end
	return false
end

-- ============================================================
-- Runtime-only epoch table for OTHER clients (spec 10: never saved).
-- Also doubles as the "have I heard from this person at all" presence
-- signal that /cbab check relies on.
-- ============================================================

local epochTable = {}

function CBAB.Comm:EpochTable()
	return epochTable
end

-- ============================================================
-- Throttled send queue (spec 8 throttle policy): hard cap 8/sec, never
-- more than 4 in any 250ms window. Enforced here, below the public Send
-- API, so every message type is covered without each caller re-checking.
-- ============================================================

local queue = {}
local sendTimes = {}
local draining = false

local function pruneSendTimes(now)
	while sendTimes[1] and now - sendTimes[1] > 1.0 do
		table.remove(sendTimes, 1)
	end
end

local function canSendNow(now)
	pruneSendTimes(now)
	if #sendTimes >= 8 then return false end
	local recent = 0
	for _, t in ipairs(sendTimes) do
		if now - t <= 0.25 then recent = recent + 1 end
	end
	return recent < 4
end

local function rawSend(text, channel, target)
	RawSendAddonMessage(COMM_PREFIX, text, channel, target)
end

local function drainQueue()
	if #queue == 0 then
		draining = false
		return
	end
	local now = GetTime()
	if canSendNow(now) then
		local msg = table.remove(queue, 1)
		sendTimes[#sendTimes + 1] = now
		rawSend(msg.text, msg.channel, msg.target)
		CBAB:After(0.05, drainQueue)
	else
		CBAB:After(0.1, drainQueue)
	end
end

local function enqueue(text, channel, target)
	queue[#queue + 1] = { text = text, channel = channel, target = target }
	if not draining then
		draining = true
		drainQueue()
	end
end

-- ============================================================
-- CBAB.Comm:Send -- serialize, compress, chunk, enqueue.
-- ============================================================

local msgCounter = 0

function CBAB.Comm:Send(msgType, payload, channel, target)
	if not channel then return end

	local envelope = { t = msgType, p = payload }
	local serialized = LibSerialize:Serialize(envelope)
	local compressed = LibDeflate:CompressDeflate(serialized)
	local encoded = LibDeflate:EncodeForWoWAddonChannel(compressed)

	msgCounter = (msgCounter + 1) % 1000
	local id = msgCounter
	local total = math.max(1, math.ceil(#encoded / CHUNK_SIZE))

	for i = 1, total do
		local from = (i - 1) * CHUNK_SIZE + 1
		local chunk = encoded:sub(from, from + CHUNK_SIZE - 1)
		local header = ("%03d%03d%03d"):format(id, i, total)
		enqueue(header .. chunk, channel, target)
	end
end

-- ============================================================
-- Same-epoch collision tiebreak (spec 8): deterministic, no round trip.
-- Direction (later timestamp wins, then lexicographically later author)
-- isn't specified by the spec beyond "deterministic" -- any fixed rule
-- both sides compute identically satisfies it; this is the one chosen.
-- ============================================================

local function tiebreakWinner(a, b)
	if a.epoch ~= b.epoch then return a.epoch > b.epoch end
	if a.timestamp ~= b.timestamp then return a.timestamp > b.timestamp end
	return a.author > b.author
end

-- ============================================================
-- Inbound message handlers
-- ============================================================

local function handleSelf(sender, payload)
	if type(payload) ~= "table" then return end
	local nameRealm = senderNameRealm(sender)
	if nameRealm == myNameRealm() then return end

	local accepted = CBAB.Cap:Put(nameRealm, payload, "guild")
	if accepted then
		CBAB:Fire("CAPABILITY_CHANGED", nameRealm, payload)
	end
end

local function handlePing(sender, payload)
	local name = senderNameOnly(sender)
	local epoch = (payload and payload.epoch) or 0
	epochTable[name] = math.max(epochTable[name] or 0, epoch)
end

-- HELLO gets two independent replies (spec 8):
--  1. A cheap PING presence beacon from EVERYONE, 0-1.5s jitter -- this is
--     what lets /cbab check tell "no addon" apart from "nothing new to
--     offer", since spec 8 only mandates a full reply from those with
--     strictly newer data.
--  2. A full whispered PUSH from whoever has newer data: the leader
--     replies on a 0-1.5s jitter unconditionally ("preferentially");
--     everyone else waits 1-2s and, right before firing, re-checks
--     epochTable[sender] -- if it's already caught up to my epoch (via a
--     PING/PUSH they must have gotten from someone faster), skip. Private
--     whispers between two OTHER clients can't be observed directly, so
--     this epochTable check is the best available proxy for "did someone
--     else already answer" -- occasional redundant whispers are an
--     accepted cost, not a correctness bug.
local function handleHello(sender, payload, channel)
	local name = senderNameOnly(sender)
	if name == UnitName("player") then return end

	local theirEpoch = (payload and payload.epoch) or 0
	epochTable[name] = math.max(epochTable[name] or 0, theirEpoch)

	local profile = CBAB.DB:Profile()
	local myEpoch = (profile and profile.assignment and profile.assignment.epoch) or 0

	CBAB:After(math.random() * 1.5, function()
		CBAB.Comm:Send("PING", { epoch = myEpoch }, channel)
	end)

	if profile and profile.assignment and myEpoch > theirEpoch then
		local isLeader = UnitIsGroupLeader("player")
		local delay = isLeader and (math.random() * 1.5) or (1 + math.random())
		CBAB:After(delay, function()
			if not isLeader and (epochTable[name] or 0) >= myEpoch then
				return
			end
			CBAB.Comm:Send("PUSH", profile.assignment, "WHISPER", sender)
		end)
	end
end

local function handlePushAck(sender, payload)
	if payload and payload.superseded then
		CBAB:Print(("your push (epoch %s) was superseded by %s"):format(
			tostring(payload.epoch), tostring(payload.winner)))
	end
end

-- The authority core (spec 8). Accept only if incomingEpoch > myEpoch, or
-- from a verified leader/assist at equal-or-newer epoch. A "local"
-- override is only ever displaced by a STRICTLY higher epoch, per spec's
-- exact wording ("survives until the next higher-epoch push"). A same-
-- epoch collision between two genuinely pushed assignments from different
-- authors is resolved via the deterministic tiebreak, and the loser is
-- whispered a PUSHACK.
local function handlePush(sender, payload, channel)
	local name = senderNameOnly(sender)
	if not isKnownSender(name) then return end
	if type(payload) ~= "table" or type(payload.epoch) ~= "number" then return end

	local profile = CBAB.DB:Profile()
	if not profile then return end

	local current = profile.assignment
	local myEpoch = (current and current.epoch) or 0

	if current and current.source == "local" and payload.epoch <= myEpoch then
		return
	end

	local senderUnit
	for _, m in pairs(CBAB.Roster:Get()) do
		if m.name == name then
			senderUnit = m.unit
			break
		end
	end
	local isVerified = senderUnit ~= nil
		and (UnitIsGroupLeader(senderUnit) or GetPartyAssignment("MAINASSIST", senderUnit))

	local accept = false
	if payload.epoch > myEpoch then
		accept = true
	elseif payload.epoch == myEpoch and isVerified then
		if current and current.source == "pushed" and current.author and payload.author
			and current.author ~= payload.author then
			local incoming = { epoch = payload.epoch, timestamp = payload.timestamp or 0, author = payload.author }
			local mine = { epoch = myEpoch, timestamp = current.timestamp or 0, author = current.author }
			if tiebreakWinner(incoming, mine) then
				accept = true
			else
				CBAB.Debug:Log("PUSH rejected (tiebreak loss): from", name, "epoch", payload.epoch, "vs mine", mine.author)
				CBAB.Comm:Send("PUSHACK", { epoch = myEpoch, superseded = true, winner = mine.author }, "WHISPER", sender)
				return
			end
		else
			accept = true
		end
	end

	if not accept then
		CBAB.Debug:Log("PUSH rejected: from", name, "epoch", payload.epoch, "myEpoch", myEpoch, "verified", tostring(isVerified))
		return
	end

	CBAB.Debug:Log("PUSH accepted: from", name, "epoch", payload.epoch)
	payload.source = "pushed"
	profile.assignment = payload
	profile.modified = time()
	epochTable[name] = math.max(epochTable[name] or 0, payload.epoch)
	CBAB:Fire("ASSIGNMENT_CHANGED")
	CBAB:Print(("received assignment push from %s (epoch %d)"):format(payload.author or name, payload.epoch))

	if channel == "WHISPER" then
		local broadcastChannel = groupChannel()
		if broadcastChannel then
			CBAB.Comm:Send("PING", { epoch = payload.epoch }, broadcastChannel)
		end
	end
end

-- OVERRIDE and TANKFLAGS aren't built yet -- nothing in this addon sends
-- them. Received ones are just re-fired as CBAB events so a future module
-- can subscribe without touching Comm.lua.
local dispatch = {
	HELLO = handleHello,
	SELF = handleSelf,
	PUSH = handlePush,
	PUSHACK = handlePushAck,
	PING = handlePing,
	OVERRIDE = function(sender, payload) CBAB:Fire("COMM_OVERRIDE", senderNameOnly(sender), payload) end,
	TANKFLAGS = function(sender, payload) CBAB:Fire("COMM_TANKFLAGS", senderNameOnly(sender), payload) end,
}

-- ============================================================
-- Reassembly
-- ============================================================

local inbox = {}

local function handleChunk(sender, channel, text)
	if #text < 9 then return end
	local id = tonumber(text:sub(1, 3))
	local i = tonumber(text:sub(4, 6))
	local n = tonumber(text:sub(7, 9))
	if not (id and i and n) then return end
	local data = text:sub(10)

	inbox[sender] = inbox[sender] or {}
	local msg = inbox[sender][id]
	if not msg then
		msg = { total = n, parts = {} }
		inbox[sender][id] = msg
	end
	msg.parts[i] = data

	for p = 1, msg.total do
		if not msg.parts[p] then return end
	end
	inbox[sender][id] = nil

	local encoded = table.concat(msg.parts, "", 1, msg.total)

	-- Never trust the wire. A malformed/corrupted packet from a stale or
	-- hostile client is silently dropped, never surfaced as an error.
	local ok, envelope = pcall(function()
		local compressed = LibDeflate:DecodeForWoWAddonChannel(encoded)
		if not compressed then error("bad encoding", 0) end
		local serialized = LibDeflate:DecompressDeflate(compressed)
		if not serialized then error("bad compression", 0) end
		local deserializeOk, data2 = LibSerialize:Deserialize(serialized)
		if not deserializeOk then error("bad serialization", 0) end
		return data2
	end)

	if not ok or type(envelope) ~= "table" or type(envelope.t) ~= "string" then
		return
	end

	local handler = dispatch[envelope.t]
	if handler then
		handler(sender, envelope.p, channel)
	end
end

CBAB:On("CHAT_MSG_ADDON", "comm:receive", function(prefix, text, channel, sender)
	if prefix ~= COMM_PREFIX then return end
	handleChunk(sender, channel, text)
end)

-- ============================================================
-- CBAB.Comm:BroadcastSelf / Hello / PushAssignment
-- ============================================================

local lastSelfBroadcast = 0
local SELF_INTERVAL = 10

function CBAB.Comm:BroadcastSelf()
	local now = GetTime()
	if now - lastSelfBroadcast < SELF_INTERVAL then return end
	lastSelfBroadcast = now

	local entry = CBAB.Cap:ScanSelf()
	if IsInGuild() then
		self:Send("SELF", entry, "GUILD")
	end
	local channel = groupChannel()
	if channel then
		self:Send("SELF", entry, channel)
	end
end

-- Fires on both the local rescan (Capability.lua) and a received SELF
-- (handleSelf above) -- CAPABILITY_CHANGED doesn't distinguish, so this
-- only re-broadcasts for the local entry, or it would echo forever.
CBAB:On("CAPABILITY_CHANGED", "comm:broadcastself", function(nameRealm)
	if nameRealm == myNameRealm() then
		CBAB.Comm:BroadcastSelf()
	end
end)

function CBAB.Comm:Hello()
	local channel = groupChannel()
	if not channel then return end
	local profile = CBAB.DB:Profile()
	local myEpoch = (profile and profile.assignment and profile.assignment.epoch) or 0
	self:Send("HELLO", { epoch = myEpoch }, channel)
end

local wasInGroup = IsInGroup()
CBAB:On("GROUP_ROSTER_UPDATE", "comm:hello-on-join", function()
	local nowInGroup = IsInGroup()
	if nowInGroup and not wasInGroup then
		CBAB.Comm:Hello()
	end
	wasInGroup = nowInGroup
end)
CBAB:On("PLAYER_ENTERING_WORLD", "comm:hello-on-login", function()
	if IsInGroup() then
		CBAB.Comm:Hello()
	end
end)

local lastPush = 0
local PUSH_INTERVAL = 3

function CBAB.Comm:PushAssignment()
	if not CBAB:Mode().coordinator then
		CBAB:Print("only the leader or an assist can push")
		return
	end

	local now = GetTime()
	if now - lastPush < PUSH_INTERVAL then
		CBAB:Print("push is rate-limited -- try again in a moment")
		return
	end

	local profile = CBAB.DB:Profile()
	if not profile or not profile.assignment then
		CBAB:Print("nothing to push -- run /cbab solve first")
		return
	end

	local channel = groupChannel()
	if not channel then
		CBAB:Print("not in a group -- nothing to push to")
		return
	end

	lastPush = now
	profile.assignment.source = "pushed"
	self:Send("PUSH", profile.assignment, channel)
	CBAB:Print(("pushed epoch %d to %s"):format(profile.assignment.epoch, channel))
end

CBAB.SlashCommands.push = function() CBAB.Comm:PushAssignment() end

-- ============================================================
-- /cbab epoch, /cbab check
-- ============================================================

CBAB.SlashCommands.epoch = function()
	local profile = CBAB.DB:Profile()
	local myEpoch = (profile and profile.assignment and profile.assignment.epoch) or 0
	CBAB:Print(("my epoch: %d"):format(myEpoch))
	for name, epoch in pairs(epochTable) do
		CBAB:Print(("  %s: %d"):format(name, epoch))
	end
end

-- Only paladins are checked (spec: non-paladins aren't expected to have
-- the addon, so their silence is never listed). Presence is judged off
-- epochTable, populated by the PING every client sends in reply to any
-- HELLO regardless of whether they had anything newer to offer.
CBAB.SlashCommands.check = function()
	CBAB.Comm:Hello()
	CBAB:Print("checking for paladin responses...")
	CBAB:After(3, function()
		local silent = {}
		for _, p in ipairs(CBAB.Roster:Paladins()) do
			if epochTable[p.name] == nil then
				silent[#silent + 1] = p.name
			end
		end
		if #silent == 0 then
			CBAB:Print("all paladins responded")
		else
			CBAB:Print("no response from: " .. table.concat(silent, ", "))
		end
	end)
end
