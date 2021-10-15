---
-- @Liquipedia
-- wiki=commons
-- page=Module:Match
--
-- Please see https://github.com/Liquipedia/Lua-Modules to contribute
--

local Arguments = require('Module:Arguments')
local Array = require('Module:Array')
local FeatureFlag = require('Module:FeatureFlag')
local Json = require('Module:Json')
local Logic = require('Module:Logic')
local Lua = require('Module:Lua')
local MatchGroupUtil = require('Module:MatchGroup/Util')
local PageVariableNamespace = require('Module:PageVariableNamespace')
local Table = require('Module:Table')

local globalVars = PageVariableNamespace()

local Match = {}

function Match.storeFromArgs(frame)
	Match.store(Arguments.getArgs(frame))
end

function Match.toEncodedJson(frame)
	local args = Arguments.getArgs(frame)
	return FeatureFlag.with({dev = Logic.readBoolOrNil(args.dev)}, function()
		local Match_ = Lua.import('Module:Match', {requireDevIfEnabled = true})
		return Match_.withPerformanceSetup(function()
			return Match_._toEncodedJson(args)
		end)
	end)
end

function Match._toEncodedJson(matchArgs)
	-- handle tbd and literals for opponents
	for opponentIndex = 1, matchArgs[1] or 2 do
		local opponent = matchArgs['opponent' .. opponentIndex]
		if Logic.isEmpty(opponent) then
			matchArgs['opponent' .. opponentIndex] = {
				type = 'literal', template = 'tbd', name = matchArgs['opponent' .. opponentIndex .. 'literal']
			}
		end
	end

	-- handle literals for qualifiers
	matchArgs.bracketdata = {
		qualwinLiteral = matchArgs.qualwinliteral,
		qualloseLiteral = matchArgs.qualloseliteral,
	}

	for key, map in Table.iter.pairsByPrefix(matchArgs, 'map') do
		matchArgs[key] = Json.parseIfString(map)
	end
	for key, opponent in Table.iter.pairsByPrefix(matchArgs, 'opponent') do
		matchArgs[key] = Json.parseIfString(opponent)
	end

	return Json.stringify(matchArgs)
end

function Match.storeMatchGroup(matchRecords, options)
	options = options or {}
	options = {
		bracketId = options.bracketId,
		storeMatch1 = Logic.nilOr(options.storeMatch1, true),
		storeMatch2 = Logic.nilOr(options.storeMatch2, true),
		storePageVar = Logic.nilOr(options.storePageVar, false),
		storeSmw = Logic.nilOr(options.storeSmw, true),
	}
	local LegacyMatch = (options.storeMatch1 or options.storeSmw) and Lua.requireIfExists('Module:Match/Legacy')

	matchRecords = Array.map(matchRecords, function(matchRecord)
		local records = Match.splitRecordsByType(matchRecord)
		Match.prepareRecords(records)
		Match.populateEdges(records)
		return records.matchRecord
	end)

	-- Store matches in a page variable to bypass LPDB on the same page
	if options.storePageVar then
		assert(options.bracketId, 'Match.storeMatchGroup: Expect options.bracketId to specified')
		globalVars:set('match2bracket_' .. options.bracketId, Json.stringify(matchRecords))
		globalVars:set('match2bracketindex', (globalVars:get('match2bracketindex') or 0) + 1)
	end

	if LegacyMatch or options.storeMatch2 then
		local matchRecordsCopy = Array.map(matchRecords, Match.copyRecords)
		Array.forEach(matchRecordsCopy, Match.encodeJson)

		if LegacyMatch then
			Array.forEach(matchRecordsCopy, function(matchRecord)
				LegacyMatch.storeMatch(matchRecord, options)
			end)
		end

		if options.storeMatch2 then
			Array.forEach(matchRecordsCopy, Match._storeMatch2)
		end
	end
end

function Match.store(match, options)
	Match.storeMatchGroup({match}, type(options) == 'table' and options or nil)
end

--[[
Normalize edges between a match record and its subobject records. For instance,
there are 3 ways each to connect to game records, opponent records, and player records:

match.match2games (*)
match.games
match.mapX
match.match2opponents (*)
match.opponents
match.opponentX
opponent.match2players (*)
opponent.players
opponent.playerX

After Match.normalizeEdges only the starred fields (*) will be present.
]]
function Match.normalizeEdges(match)
	local records = Match.splitRecordsByType(match)
	Match.populateEdges(records)
	return records.matchRecord
end

--[[
Groups subobjects by type (game, opponent, player), and removes direct
references between a match record and its subobject records.
]]
function Match.splitRecordsByType(match)
	local gameRecords = match.match2games or match.games or {}
	match.match2games = nil
	match.games = nil
	for key, gameRecord in Table.iter.pairsByPrefix(match, 'map') do
		match[key] = nil
		table.insert(gameRecords, gameRecord)
	end

	local opponentRecords = match.match2opponents or match.opponents or {}
	match.match2opponents = nil
	match.opponents = nil
	for key, opponentRecord in Table.iter.pairsByPrefix(match, 'opponent') do
		match[key] = nil
		table.insert(opponentRecords, opponentRecord)
	end

	local playerRecords = {}
	for opponentIndex, opponentRecord in ipairs(opponentRecords) do
		table.insert(playerRecords, opponentRecord.match2players or opponentRecord.players or {})
		opponentRecord.match2players = nil
		opponentRecord.players = nil
		for key, playerRecord in Table.iter.pairsByPrefix(match, 'opponent' .. opponentIndex .. '_p') do
			match[key] = nil
			table.insert(playerRecords[#playerRecords], playerRecord)
		end
	end

	return {
		gameRecords = gameRecords,
		matchRecord = match,
		opponentRecords = opponentRecords,
		playerRecords = playerRecords,
	}
end

--[[
Adds direct references between a match record and its subobjects.
]]
function Match.populateEdges(records)
	local matchRecord = records.matchRecord
	matchRecord.match2opponents = records.opponentRecords
	matchRecord.match2games = records.gameRecords

	for opponentIndex, opponentRecord in ipairs(records.opponentRecords) do
		opponentRecord.match2players = records.playerRecords[opponentIndex]
	end
end

--[[
Copies just the match and subobject records. Assumes that edges have been
normalized.
]]
function Match.copyRecords(matchRecord)
	return Table.merge(matchRecord, {
		match2opponents = Array.map(matchRecord.match2opponents, function(opponentRecord)
			return Table.merge(opponentRecord, {
				match2players = Array.map(opponentRecord.match2players, Table.copy)
			})
		end),
		match2games = Array.map(matchRecord.match2games, Table.copy),
	})
end

function Match.stringifyIfNotEmpty(tbl)
	return Table.isNotEmpty(tbl) and Json.stringify(tbl) or nil
end

function Match.encodeJson(matchRecord)
	matchRecord.match2bracketdata = Match.stringifyIfNotEmpty(matchRecord.match2bracketdata)
	matchRecord.stream = Match.stringifyIfNotEmpty(matchRecord.stream)
	matchRecord.links = Match.stringifyIfNotEmpty(matchRecord.links)
	matchRecord.extradata = Match.stringifyIfNotEmpty(matchRecord.extradata)

	for _, opponentRecord in ipairs(matchRecord.match2opponents) do
		opponentRecord.extradata = Match.stringifyIfNotEmpty(opponentRecord.extradata)
		for _, playerRecord in ipairs(opponentRecord.match2players) do
			playerRecord.extradata = Match.stringifyIfNotEmpty(playerRecord.extradata)
		end
	end
	for _, gameRecord in ipairs(matchRecord.match2games) do
		gameRecord.extradata = Match.stringifyIfNotEmpty(gameRecord.extradata)
		gameRecord.participants = Match.stringifyIfNotEmpty(gameRecord.participants)
		gameRecord.scores = Match.stringifyIfNotEmpty(gameRecord.scores)
	end
end

function Match._storeMatch2(unsplitMatchRecord)
	local records = Match.splitRecordsByType(unsplitMatchRecord)
	local matchRecord = records.matchRecord

	local opponentIndexes = Array.map(records.opponentRecords, function(opponentRecord, opponentIndex)
		local playerIndexes = Array.map(records.playerRecords[opponentIndex], function(player, playerIndex)
			return mw.ext.LiquipediaDB.lpdb_match2player(
				matchRecord.match2id .. '_m2o_' .. opponentIndex .. '_m2p_' .. playerIndex,
				player
			)
		end)

		opponentRecord.match2players = table.concat(playerIndexes)
		return mw.ext.LiquipediaDB.lpdb_match2opponent(
			matchRecord.match2id .. '_m2o_' .. opponentIndex,
			opponentRecord
		)
	end)

	local gameIndexes = Array.map(records.gameRecords, function(gameRecord, gameIndex)
		return mw.ext.LiquipediaDB.lpdb_match2game(
			matchRecord.match2id .. '_m2g_' .. gameIndex,
			gameRecord
		)
	end)

	matchRecord.match2games = table.concat(gameIndexes)
	matchRecord.match2opponents = table.concat(opponentIndexes)
	mw.ext.LiquipediaDB.lpdb_match2(matchRecord.match2id, matchRecord)
end

function Match.templateFromMatchID(frame)
	local args = Arguments.getArgs(frame)
	local matchId = args[1] or 'match id is empty'
	return MatchGroupUtil.matchIdToKey(matchId)
end

function Match.prepareRecords(records)
	Match.prepareMatchRecord(records.matchRecord)
	for opponentIndex, opponentRecord in ipairs(records.opponentRecords) do
		Match.restrictInPlace(opponentRecord, Match.opponentFields)
		for _, playerRecord in ipairs(records.playerRecords[opponentIndex]) do
			Match.restrictInPlace(playerRecord, Match.playerFields)
		end
	end
	for _, gameRecord in ipairs(records.gameRecords) do
		Match.restrictInPlace(gameRecord, Match.gameFields)
	end
end

function Match.prepareMatchRecord(match)
	match.dateexact = Logic.readBool(match.dateexact) and 1 or 0
	match.finished = Logic.readBool(match.finished) and 1 or 0
	match.match2bracketdata = match.match2bracketdata or match.bracketdata
	match.match2bracketid = match.match2bracketid or match.bracketid
	match.match2id = match.match2id or match.bracketid .. '_' .. match.matchid
	Match.restrictInPlace(match, Match.matchFields)
end

Match.matchFields = Table.map({
	'bestof',
	'date',
	'dateexact',
	'extradata',
	'finished',
	'game',
	'icon',
	'icondark',
	'links',
	'liquipediatier',
	'liquipediatiertype',
	'lrthread',
	'match2bracketdata',
	'match2bracketid',
	'match2id',
	'mode',
	'parent',
	'parentname',
	'patch',
	'publishertier',
	'resulttype',
	'series',
	'shortname',
	'status',
	'stream',
	'tickername',
	'tournament',
	'type',
	'vod',
	'walkover',
	'winner',
}, function(_, field) return field, true end)

Match.opponentFields = Table.map({
	'extradata',
	'icon',
	'name',
	'placement',
	'score',
	'status',
	'template',
	'type',
}, function(_, field) return field, true end)

Match.playerFields = Table.map({
	'displayname',
	'extradata',
	'flag',
	'name',
}, function(_, field) return field, true end)

Match.gameFields = Table.map({
	'date',
	'extradata',
	'game',
	'length',
	'map',
	'mode',
	'participants',
	'resulttype',
	'rounds',
	'scores',
	'subgroup',
	'type',
	'vod',
	'walkover',
	'winner',
}, function(_, field) return field, true end)

function Match.restrictInPlace(record, allowedKeys)
	for key, _ in pairs(record) do
		if not allowedKeys[key] then
			record[key] = nil
		end
	end
end

function Match.withPerformanceSetup(f)
	if FeatureFlag.get('perf') then
		local matchGroupConfig = Lua.loadDataIfExists('Module:MatchGroup/Config')
		local perfConfig = Table.getByPathOrNil(matchGroupConfig, {'subobjectPerf'}) or {}
		return require('Module:Performance/Util').withSetup(perfConfig, f)
	else
		return f()
	end
end

return Match
