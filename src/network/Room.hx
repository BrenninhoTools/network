package network;

import network.Types;

@:allow(network.Client)
class Room
{
	public var id(default, null):String;
	public var name(default, null):String;
	public var host(default, null):Int;
	public var maxPlayers(default, null):Int;
	public var locked(default, null):Bool;
	public var started(default, null):Bool;
	public var meta(default, null):Dynamic;
	public var state(default, null):Dynamic;
	public var players(default, null):Map<Int, PlayerInfo> = new Map();

	public var playerCount(get, never):Int;

	public function new(data:Dynamic)
	{
		apply(data);
	}

	function apply(data:Dynamic):Void
	{
		id = data.id;
		name = data.name;
		host = data.host;
		maxPlayers = data.maxPlayers;
		locked = data.locked == true;
		started = data.started == true;
		meta = data.meta != null ? data.meta : {};
		state = data.state != null ? data.state : {};
		players.clear();
		var list:Array<Dynamic> = data.players;
		if (list != null)
			for (player in list)
				players.set(player.id, {id: player.id, name: player.name, data: player.data != null ? player.data : {}});
	}

	public function getPlayer(id:Int):Null<PlayerInfo>
	{
		return players.get(id);
	}

	public function getState(key:String, ?fallback:Dynamic):Dynamic
	{
		return Reflect.hasField(state, key) ? Reflect.field(state, key) : fallback;
	}

	public function playerList():Array<PlayerInfo>
	{
		var list:Array<PlayerInfo> = [for (player in players) player];
		list.sort(function(a, b) return a.id - b.id);
		return list;
	}

	function get_playerCount():Int
	{
		var count:Int = 0;
		for (_ in players)
			count++;
		return count;
	}
}
