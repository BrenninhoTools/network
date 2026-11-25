package;

import network.Client;
import network.Leaderboard;
import network.Http;

class TestClient
{
	static var steps:Array<String> = [];
	static var failed:Bool = false;
	static var done:Bool = false;
	static var started:Float = 0;

	static function check(condition:Bool, label:String):Void
	{
		if (!condition)
		{
			failed = true;
			log('FAIL $label');
		}
		else steps.push(label);
	}

	static function log(text:String):Void
	{
		#if sys
		Sys.println(text);
		#else
		js.Syntax.code("console.log({0})", text);
		#end
	}

	static function main():Void
	{
		var port:String = #if sys Sys.getEnv("NETWORK_PORT") #else js.Syntax.code("process.env.NETWORK_PORT") #end;
		var url:String = 'ws://127.0.0.1:$port/';
		var a:Client = new Client();
		var b:Client = new Client();
		var board:Leaderboard = new Leaderboard('http://127.0.0.1:$port');

		a.onConnect = function()
		{
			check(a.id > 0, "a connected");
			a.createRoom({name: "Haxe Room", maxPlayers: 2, meta: {song: "tutorial"}}, function(room, error)
			{
				check(error == null && room != null && room.name == "Haxe Room", "room created");
				check(a.isHost, "a is host");
				b.connect(url, "Bob");
			});
		};

		b.onConnect = function()
		{
			b.listRooms(function(rooms)
			{
				check(rooms.length == 1 && rooms[0].meta.song == "tutorial", "rooms listed");
				b.joinRoom(rooms[0].id.toLowerCase(), null, function(room, error)
				{
					check(error == null && room.playerCount == 2, "b joined");
					b.send("note", {lane: 3, time: 1.5});
					b.setPlayerData({ready: true});
				});
			});
		};

		a.on("note", function(from, data)
		{
			check(from == b.id && data.lane == 3, "note relayed");
			a.setState("speed", 2.5);
			a.chat("hello from haxe");
			var bytes:haxe.io.Bytes = haxe.io.Bytes.alloc(3);
			bytes.set(0, 7);
			bytes.set(1, 8);
			bytes.set(2, 9);
			a.sendBinary(bytes);
		});

		a.onPlayerData = function(player)
		{
			check(player.data.ready == true, "player data synced");
		};

		b.onState = function(key, value)
		{
			check(key == "speed" && value == 2.5 && b.room.getState("speed") == 2.5, "state synced");
		};

		b.onChat = function(player, text)
		{
			check(text == "hello from haxe" && player.name == "Alice", "chat received");
		};

		b.onBinary = function(from, bytes)
		{
			check(from == a.id && bytes.length == 3 && bytes.get(2) == 9, "binary relayed");
			a.submitScore("haxe", 1234, null, function(rank, error)
			{
				check(rank == 1 && error == null, "score submitted");
				board.top("haxe", 5, function(scores)
				{
					check(scores.length == 1 && scores[0].name == "Alice", "leaderboard over http");
					b.joinRoom("ZZZZZZ", null, function(room, error)
					{
						check(room == null && error != null && error.code == "no_room", "join error reported");
						b.leaveRoom();
						a.onPeerLeave = function(player, reason)
						{
							check(player.name == "Bob", "peer left");
							check(a.latency >= 0, "latency measured");
							a.disconnect();
							b.disconnect();
							done = true;
						};
					});
				}, function(error) check(false, "http error " + error));
			});
		};

		a.onError = function(error) log("a error " + error.code + " " + error.message);
		b.onError = function(error) log("b error " + error.code + " " + error.message);

		a.pingInterval = 0.05;
		a.connect(url, "Alice");
		started = haxe.Timer.stamp();

		#if sys
		while (!done && haxe.Timer.stamp() - started < 10)
		{
			a.update();
			b.update();
			Http.update();
			Sys.sleep(0.005);
		}
		finish();
		#else
		var timer:haxe.Timer = new haxe.Timer(5);
		timer.run = function()
		{
			a.update();
			b.update();
			Http.update();
			if (done || haxe.Timer.stamp() - started > 10)
			{
				timer.stop();
				finish();
			}
		};
		#end
	}

	static function finish():Void
	{
		if (!done) failed = true;
		log('${steps.length} checks passed' + (failed ? ", FAILED" : ""));
		if (!done) log("timed out after: " + steps.join(", "));
		#if sys
		Sys.exit(failed ? 1 : 0);
		#else
		js.Syntax.code("process.exit({0})", failed ? 1 : 0);
		#end
	}
}
