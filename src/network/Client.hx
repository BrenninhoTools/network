package network;

import haxe.Json;
import haxe.io.Bytes;
import network.Types;

class Client
{
	public static inline var VERSION:String = "1.0.0";

	public var socket(default, null):WebSocket;
	public var url(default, null):String;
	public var id(default, null):Int = -1;
	public var name(default, null):String = "";
	public var data(default, null):Dynamic = {};
	public var room(default, null):Null<Room>;
	public var motd(default, null):String = "";
	public var serverVersion(default, null):String = "";

	public var connected(get, never):Bool;
	public var inRoom(get, never):Bool;
	public var isHost(get, never):Bool;

	public var latency(default, null):Float = 0;
	public var serverTimeOffset(default, null):Float = 0;
	public var pingInterval:Float = 2;
	public var requestTimeout:Float = 10;

	public var autoReconnect:Bool = false;
	public var reconnectDelay:Float = 2;
	public var maxReconnectDelay:Float = 30;

	public var onConnect:Void->Void;
	public var onDisconnect:Int->String->Void;
	public var onError:NetworkError->Void;
	public var onRoomList:Array<RoomSummary>->Void;
	public var onJoin:Room->Void;
	public var onLeave:Void->Void;
	public var onRoomChanged:Room->Void;
	public var onPeerJoin:PlayerInfo->Void;
	public var onPeerLeave:PlayerInfo->String->Void;
	public var onHostChanged:Int->Void;
	public var onState:String->Dynamic->Void;
	public var onPlayerData:PlayerInfo->Void;
	public var onChat:PlayerInfo->String->Void;
	public var onStart:Dynamic->Float->Void;
	public var onStop:Dynamic->Void;
	public var onKicked:String->Void;
	public var onMessage:String->Int->Dynamic->Void;
	public var onBinary:Int->Bytes->Void;
	public var onRaw:Dynamic->Void;

	var handlers:Map<String, Array<Int->Dynamic->Void>> = new Map();
	var requests:Map<Int, PendingRequest> = new Map();
	var nextRequest:Int = 1;
	var lastPing:Float = 0;
	var wantConnected:Bool = false;
	var reconnectAt:Float = -1;
	var currentDelay:Float = 0;

	public function new() {}

	public function connect(url:String, name:String, ?data:Dynamic):Void
	{
		this.url = url;
		this.name = name;
		this.data = data != null ? data : {};
		wantConnected = true;
		currentDelay = reconnectDelay;
		open();
	}

	public function disconnect():Void
	{
		wantConnected = false;
		reconnectAt = -1;
		if (socket != null) socket.close(1000, "Bye");
	}

	public function update():Void
	{
		if (socket != null) socket.update();

		var now:Float = haxe.Timer.stamp();

		if (connected && pingInterval > 0 && now - lastPing >= pingInterval)
		{
			lastPing = now;
			raw({t: "ping", time: now * 1000});
		}

		if (requests.iterator().hasNext())
		{
			for (key in [for (k in requests.keys()) k])
			{
				var pending:PendingRequest = requests.get(key);
				if (now - pending.sent > requestTimeout)
				{
					requests.remove(key);
					if (pending.callback != null) pending.callback(null, {code: "timeout", message: "The server did not answer"});
				}
			}
		}

		if (reconnectAt >= 0 && now >= reconnectAt)
		{
			reconnectAt = -1;
			open();
		}
	}

	public function serverTime():Float
	{
		return haxe.Timer.stamp() * 1000 + serverTimeOffset;
	}

	public function on(event:String, handler:Int->Dynamic->Void):Void
	{
		var list:Array<Int->Dynamic->Void> = handlers.get(event);
		if (list == null) handlers.set(event, list = []);
		list.push(handler);
	}

	public function off(event:String, ?handler:Int->Dynamic->Void):Void
	{
		if (handler == null)
		{
			handlers.remove(event);
			return;
		}
		var list:Array<Int->Dynamic->Void> = handlers.get(event);
		if (list != null) list.remove(handler);
	}

	public function listRooms(?callback:Array<RoomSummary>->Void):Void
	{
		request({t: "list"}, function(message, error)
		{
			if (error != null) return;
			if (callback != null) callback(message.rooms);
		});
	}

	public function createRoom(?options:RoomOptions, ?callback:Room->NetworkError->Void):Void
	{
		var message:Dynamic = {t: "create"};
		if (options != null)
		{
			message.name = options.name;
			message.maxPlayers = options.maxPlayers;
			message.password = options.password;
			message.meta = options.meta;
			Reflect.setField(message, "private", options.isPrivate == true);
		}
		request(message, joinCallback(callback));
	}

	public function joinRoom(id:String, ?password:String, ?callback:Room->NetworkError->Void):Void
	{
		request({t: "join", id: id, password: password}, joinCallback(callback));
	}

	public function quickJoin(?meta:Dynamic, maxPlayers:Int = 2, ?callback:Room->NetworkError->Void):Void
	{
		request({t: "quick", meta: meta != null ? meta : {}, maxPlayers: maxPlayers}, joinCallback(callback));
	}

	public function leaveRoom():Void
	{
		if (room == null) return;
		raw({t: "leave"});
		room = null;
		if (onLeave != null) onLeave();
	}

	public function send(event:String, ?payload:Dynamic, ?to:Array<Int>, echo:Bool = false):Bool
	{
		var message:Dynamic = {t: "msg", event: event, data: payload};
		if (to != null) message.to = to;
		if (echo) message.echo = true;
		return raw(message);
	}

	public inline function sendTo(target:Int, event:String, ?payload:Dynamic):Bool
	{
		return send(event, payload, [target]);
	}

	public function sendBinary(bytes:Bytes):Bool
	{
		return socket != null && socket.sendBytes(bytes);
	}

	public function chat(text:String):Bool
	{
		return raw({t: "chat", text: text});
	}

	public function rename(newName:String):Bool
	{
		name = newName;
		return raw({t: "rename", name: newName});
	}

	public function setPlayerData(values:Dynamic):Bool
	{
		for (field in Reflect.fields(values))
		{
			var value:Dynamic = Reflect.field(values, field);
			if (value == null) Reflect.deleteField(data, field);
			else Reflect.setField(data, field, value);
		}
		return raw({t: "player", data: values});
	}

	public function setState(key:String, value:Dynamic):Bool
	{
		return raw({t: "state", key: key, value: value});
	}

	public function setRoom(?name:String, ?meta:Dynamic, ?maxPlayers:Int, ?isPrivate:Bool, ?password:String):Bool
	{
		var message:Dynamic = {t: "meta"};
		if (name != null) message.name = name;
		if (meta != null) message.meta = meta;
		if (maxPlayers != null) message.maxPlayers = maxPlayers;
		if (isPrivate != null) Reflect.setField(message, "private", isPrivate);
		if (password != null) message.password = password.length > 0 ? password : null;
		return raw(message);
	}

	public function start(?payload:Dynamic, delayMs:Float = 0):Bool
	{
		return raw({t: "start", data: payload, delay: delayMs});
	}

	public function stop(?payload:Dynamic):Bool
	{
		return raw({t: "stop", data: payload});
	}

	public function kick(target:Int, reason:String = ""):Bool
	{
		return raw({t: "kick", id: target, reason: reason});
	}

	public function transferHost(target:Int):Bool
	{
		return raw({t: "host", id: target});
	}

	public function submitScore(board:String, score:Float, ?extra:Dynamic, ?callback:Int->NetworkError->Void):Void
	{
		request({t: "score", board: board, score: score, data: extra}, function(message, error)
		{
			if (callback != null) callback(message != null ? message.rank : -1, error);
		});
	}

	public function getScores(board:String, limit:Int = 10, callback:Array<ScoreEntry>->NetworkError->Void):Void
	{
		request({t: "scores", board: board, limit: limit}, function(message, error)
		{
			callback(message != null ? message.scores : [], error);
		});
	}

	public function raw(message:Dynamic):Bool
	{
		if (socket == null || socket.state != OPEN) return false;
		return socket.send(Json.stringify(message));
	}

	public function request(message:Dynamic, ?callback:Dynamic->NetworkError->Void):Bool
	{
		var requestId:Int = nextRequest++;
		message.r = requestId;
		if (!raw(message))
		{
			if (callback != null) callback(null, {code: "not_connected", message: "Not connected"});
			return false;
		}
		requests.set(requestId, {callback: callback, sent: haxe.Timer.stamp()});
		return true;
	}

	function joinCallback(callback:Room->NetworkError->Void):Dynamic->NetworkError->Void
	{
		return function(message:Dynamic, error:NetworkError)
		{
			if (callback != null) callback(error == null ? room : null, error);
		};
	}

	function open():Void
	{
		if (socket != null)
		{
			socket.onClose = null;
			socket.close();
		}
		socket = new WebSocket(url);
		socket.onOpen = function() raw({t: "hello", name: name, data: data, version: VERSION});
		socket.onMessage = handleText;
		socket.onBinary = handleBinary;
		socket.onError = function(message:String) dispatchError({code: "socket", message: message});
		socket.onClose = handleClose;
		socket.connect();
	}

	function handleClose(code:Int, reason:String):Void
	{
		var wasConnected:Bool = id >= 0;
		id = -1;
		room = null;
		for (pending in requests)
			if (pending.callback != null) pending.callback(null, {code: "disconnected", message: "Connection closed"});
		requests.clear();
		if (wasConnected && onDisconnect != null) onDisconnect(code, reason);
		if (wantConnected && autoReconnect)
		{
			reconnectAt = haxe.Timer.stamp() + currentDelay;
			currentDelay = Math.min(maxReconnectDelay, currentDelay * 2);
		}
	}

	function handleBinary(bytes:Bytes):Void
	{
		if (bytes.length < 4) return;
		var from:Int = (bytes.get(0) << 24) | (bytes.get(1) << 16) | (bytes.get(2) << 8) | bytes.get(3);
		if (onBinary != null) onBinary(from, bytes.sub(4, bytes.length - 4));
	}

	function handleText(text:String):Void
	{
		var message:Dynamic;
		try
		{
			message = Json.parse(text);
		}
		catch (e:Dynamic)
		{
			return;
		}

		if (onRaw != null) onRaw(message);

		var type:String = message.t;
		var requestId:Null<Int> = message.r;

		switch (type)
		{
			case "welcome":
				id = message.id;
				name = message.name;
				motd = message.motd != null ? message.motd : "";
				serverVersion = message.version;
				serverTimeOffset = message.time - haxe.Timer.stamp() * 1000;
				currentDelay = reconnectDelay;
				lastPing = haxe.Timer.stamp();
				if (onConnect != null) onConnect();
			case "pong":
				var now:Float = haxe.Timer.stamp() * 1000;
				var sample:Float = now - (message.time : Float);
				latency = latency <= 0 ? sample : latency * 0.8 + sample * 0.2;
				serverTimeOffset = (message.server : Float) + sample / 2 - now;
			case "rooms":
				if (onRoomList != null) onRoomList(message.rooms);
			case "joined":
				room = new Room(message.room);
				if (onJoin != null) onJoin(room);
			case "left":
			case "room":
				if (room != null)
				{
					room.apply(message.room);
					if (onRoomChanged != null) onRoomChanged(room);
				}
			case "peer_join":
				if (room != null)
				{
					var player:PlayerInfo = {id: message.player.id, name: message.player.name, data: message.player.data != null ? message.player.data : {}};
					room.players.set(player.id, player);
					if (onPeerJoin != null) onPeerJoin(player);
				}
			case "peer_leave":
				if (room != null)
				{
					var player:PlayerInfo = room.players.get(message.id);
					room.players.remove(message.id);
					if (player != null && onPeerLeave != null) onPeerLeave(player, message.reason);
				}
			case "host":
				if (room != null)
				{
					room.host = message.id;
					if (onHostChanged != null) onHostChanged(message.id);
				}
			case "state":
				if (room != null)
				{
					if (message.value == null) Reflect.deleteField(room.state, message.key);
					else Reflect.setField(room.state, message.key, message.value);
					if (onState != null) onState(message.key, message.value);
				}
			case "player":
				if (room != null)
				{
					var player:PlayerInfo = room.players.get(message.id);
					if (player != null)
					{
						player.name = message.name;
						player.data = message.data != null ? message.data : {};
						if (onPlayerData != null) onPlayerData(player);
					}
				}
			case "chat":
				var player:PlayerInfo = room != null ? room.players.get(message.from) : null;
				if (player == null) player = {id: message.from, name: message.name, data: {}};
				if (onChat != null) onChat(player, message.text);
			case "start":
				if (room != null) room.started = true;
				var at:Float = message.at;
				if (onStart != null) onStart(message.data, at - serverTimeOffset);
			case "stop":
				if (room != null) room.started = false;
				if (onStop != null) onStop(message.data);
			case "kicked":
				room = null;
				if (onKicked != null) onKicked(message.reason);
			case "msg":
				var event:String = message.event;
				var from:Int = message.from;
				var list:Array<Int->Dynamic->Void> = handlers.get(event);
				if (list != null)
					for (handler in list.copy())
						handler(from, message.data);
				if (onMessage != null) onMessage(event, from, message.data);
			case "error":
				var error:NetworkError = {code: message.code, message: message.message};
				if (requestId != null && requests.exists(requestId))
				{
					var pending:PendingRequest = requests.get(requestId);
					requests.remove(requestId);
					if (pending.callback != null) pending.callback(null, error);
					return;
				}
				dispatchError(error);
				return;
			default:
		}

		if (requestId != null && requests.exists(requestId))
		{
			var pending:PendingRequest = requests.get(requestId);
			requests.remove(requestId);
			if (pending.callback != null) pending.callback(message, null);
		}
	}

	function dispatchError(error:NetworkError):Void
	{
		if (onError != null) onError(error);
	}

	inline function get_connected():Bool
	{
		return socket != null && socket.state == OPEN && id >= 0;
	}

	inline function get_inRoom():Bool
	{
		return room != null;
	}

	inline function get_isHost():Bool
	{
		return room != null && room.host == id;
	}
}

private typedef PendingRequest =
{
	var callback:Dynamic->NetworkError->Void;
	var sent:Float;
}
