# network

Online multiplayer for Haxe games. The client is written in Haxe and runs on hxcpp (Windows, macOS, Linux, Android, iOS), HashLink, Neko, eval and JavaScript. The server is plain Node.js with no dependencies.

- Rooms with names, codes, passwords, private rooms, player limits and metadata
- Quick join by metadata (for example the same song and difficulty)
- Events to everyone or to chosen players, plus raw binary relay for fast data
- Shared room state (host only), per player data, chat
- Host migration, kick, transfer host, start and stop with a shared server clock
- Latency and server clock estimation for syncing
- Leaderboards over WebSocket or HTTP, saved to a JSON file
- Auto reconnect, request timeouts, rate limiting and heartbeats

## Install

```
haxelib git network https://github.com/BrenninhoTools/network
```

## Server

Requires Node.js 18 or newer.

```
cd server
node index.js --port 7777 --data data/scores.json --motd "Welcome!"
```

| Option | Environment | Default |
|---|---|---|
| `--port` | `PORT` | `7777` |
| `--host` | `HOST` | `0.0.0.0` |
| `--path` | `NETWORK_PATH` | `/` |
| `--motd` | `NETWORK_MOTD` | empty |
| `--data` | `NETWORK_DATA` | no persistence |
| `--max-clients` | `NETWORK_MAX_CLIENTS` | `1000` |
| `--max-rooms` | `NETWORK_MAX_ROOMS` | `500` |
| `--max-players` | `NETWORK_MAX_PLAYERS` | `16` |
| `--origins` | `NETWORK_ORIGINS` | any origin |
| `--quiet` | | logs on |

HTTP endpoints: `GET /health`, `GET /rooms`, `GET /scores/<board>?limit=10`, `POST /scores/<board>` with `{"name", "score", "data"}`.

Put it behind a reverse proxy with TLS (nginx, Caddy, Cloudflare) to use `wss://`.

The server can be extended from JavaScript:

```js
const { createServer } = require('./src/server');

const server = createServer({ port: 7777 });
server.on('roll', function (client, message) {
	client.send({ t: 'msg', from: 0, event: 'roll', data: Math.floor(Math.random() * 6) + 1 });
});
server.listen();
```

## Client

Call `update()` once per frame. Callbacks always run inside `update()`, on the main thread.

```haxe
import network.Client;

var client = new Client();
client.autoReconnect = true;

client.onConnect = function() client.quickJoin({song: "bopeebo", difficulty: "hard"}, 2);
client.onJoin = function(room) showRoomCode(room.id);
client.onPeerJoin = function(player) showToast(player.name + " joined");
client.onStart = function(data, localTime) startSongAt(localTime);

client.on("note", function(from, data) opponentHit(data.lane, data.time));

client.connect("ws://localhost:7777/", "Breno");

function update(elapsed:Float)
{
	client.update();
	network.Http.update();
}

client.send("note", {lane: 2, time: songPosition});
client.setPlayerData({ready: true});
if (client.isHost) client.start({song: "bopeebo"}, 3000);
```

Rooms:

```haxe
client.createRoom({name: "My room", maxPlayers: 4, password: "1234", meta: {mode: "versus"}}, function(room, error) {});
client.joinRoom("ABC123", "1234", function(room, error) if (error != null) showError(error.message));
client.listRooms(function(rooms) roomList.show(rooms));
client.setState("speed", 1.5);
client.kick(playerId, "afk");
client.leaveRoom();
```

Leaderboards:

```haxe
client.submitScore("week1-hard", 123456, {accuracy: 98.5}, function(rank, error) {});
client.getScores("week1-hard", 10, function(scores, error) {});

var board = new network.Leaderboard("https://my-server.com");
board.top("week1-hard", 10, function(scores) {});
```

Low level WebSocket, usable with any server:

```haxe
var socket = new network.WebSocket("wss://echo.example.com/");
socket.onOpen = function() socket.send("hi");
socket.onMessage = function(text) chatBox.add(text);
socket.connect();
```

On native targets `wss://` uses `sys.ssl.Socket`. Set `WebSocket.verifyCertificates = false` only for testing with self signed certificates.

## Protocol

Every message is a JSON object with a `t` field. Requests may carry `r`, which the server copies into its reply or error. Binary frames sent inside a room are relayed to the other players with the sender id prepended as a big endian 32 bit integer.

## Tests

```
cd server && npm test
bash tests/run.sh
```

## License

MIT
