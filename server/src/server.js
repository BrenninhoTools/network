'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const { handleUpgrade } = require('./websocket');
const { Leaderboards } = require('./leaderboards');

const VERSION = '1.0.0';
const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

const DEFAULTS = {
	port: 7777,
	host: '0.0.0.0',
	path: '/',
	maxPayload: 64 * 1024,
	maxClients: 1000,
	maxRooms: 500,
	maxPlayersPerRoom: 16,
	maxNameLength: 24,
	heartbeatInterval: 15000,
	heartbeatTimeout: 45000,
	rateLimit: 120,
	rateBurst: 240,
	motd: '',
	dataFile: null,
	allowedOrigins: null,
	log: true
};

function randomCode(length = 6) {
	const bytes = crypto.randomBytes(length);
	let code = '';
	for (let i = 0; i < length; i++) code += CODE_CHARS[bytes[i] % CODE_CHARS.length];
	return code;
}

function cleanText(value, max) {
	if (typeof value !== 'string') return '';
	return value.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, max);
}

function hashPassword(password) {
	if (!password) return null;
	return crypto.createHash('sha256').update(String(password)).digest('hex');
}

function isPlainObject(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

class Client {
	constructor(server, socket) {
		this.server = server;
		this.socket = socket;
		this.id = server.nextId();
		this.name = 'Player' + this.id;
		this.room = null;
		this.data = {};
		this.helloed = false;
		this.tokens = server.options.rateBurst;
		this.lastRefill = Date.now();
		this.connectedAt = Date.now();
	}

	send(message) {
		this.socket.send(JSON.stringify(message));
	}

	error(code, message, request) {
		const payload = { t: 'error', code, message };
		if (request !== undefined) payload.r = request;
		this.send(payload);
	}

	allow() {
		const now = Date.now();
		const rate = this.server.options.rateLimit;
		this.tokens = Math.min(this.server.options.rateBurst, this.tokens + ((now - this.lastRefill) / 1000) * rate);
		this.lastRefill = now;
		if (this.tokens < 1) return false;
		this.tokens -= 1;
		return true;
	}

	info() {
		return { id: this.id, name: this.name, data: this.data };
	}
}

class Room {
	constructor(server, owner, options) {
		this.server = server;
		this.id = server.uniqueCode();
		this.name = cleanText(options.name, 48) || owner.name + "'s room";
		this.maxPlayers = Math.max(1, Math.min(server.options.maxPlayersPerRoom, Number(options.maxPlayers) || 2));
		this.password = hashPassword(options.password);
		this.private = options.private === true;
		this.meta = isPlainObject(options.meta) ? options.meta : {};
		this.state = {};
		this.players = new Map();
		this.host = owner.id;
		this.started = false;
		this.createdAt = Date.now();
	}

	summary() {
		return {
			id: this.id,
			name: this.name,
			players: this.players.size,
			maxPlayers: this.maxPlayers,
			locked: this.password !== null,
			started: this.started,
			meta: this.meta
		};
	}

	full() {
		return Object.assign(this.summary(), {
			host: this.host,
			state: this.state,
			players: Array.from(this.players.values(), (client) => client.info())
		});
	}

	broadcast(message, except) {
		const text = JSON.stringify(message);
		for (const client of this.players.values()) {
			if (client !== except) client.socket.send(text);
		}
	}
}

class NetworkServer {
	constructor(options = {}) {
		this.options = Object.assign({}, DEFAULTS, options);
		this.clients = new Map();
		this.rooms = new Map();
		this.idCounter = 0;
		this.handlers = new Map();
		this.leaderboards = new Leaderboards(this.options.dataFile);
		this.http = http.createServer((request, response) => this.onRequest(request, response));
		this.http.on('upgrade', (request, socket, head) => this.onUpgrade(request, socket, head));
		this.heartbeat = null;
		this.registerDefaults();
	}

	log(...args) {
		if (this.options.log) console.log('[network]', ...args);
	}

	nextId() {
		return ++this.idCounter;
	}

	uniqueCode() {
		let code;
		do code = randomCode();
		while (this.rooms.has(code));
		return code;
	}

	on(type, handler) {
		this.handlers.set(type, handler);
		return this;
	}

	listen(port = this.options.port, host = this.options.host) {
		return new Promise((resolve) => {
			this.http.listen(port, host, () => {
				this.heartbeat = setInterval(() => this.checkHeartbeats(), this.options.heartbeatInterval);
				this.heartbeat.unref();
				const address = this.http.address();
				this.log(`listening on ${address.address}:${address.port}`);
				resolve(address);
			});
		});
	}

	close() {
		clearInterval(this.heartbeat);
		for (const client of this.clients.values()) client.socket.close(1001, 'Server shutting down');
		this.leaderboards.save();
		return new Promise((resolve) => this.http.close(() => resolve()));
	}

	verifyOrigin(request) {
		const allowed = this.options.allowedOrigins;
		if (!allowed || allowed.length === 0) return true;
		const origin = request.headers.origin;
		return !origin || allowed.includes(origin);
	}

	onUpgrade(request, socket, head) {
		const url = new URL(request.url, 'http://localhost');
		if (url.pathname !== this.options.path) {
			socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
			return;
		}
		if (this.clients.size >= this.options.maxClients) {
			socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
			return;
		}
		handleUpgrade(request, socket, head, { maxPayload: this.options.maxPayload, verify: (req) => this.verifyOrigin(req) }, (connection) => this.onConnection(connection));
	}

	onConnection(socket) {
		const client = new Client(this, socket);
		this.clients.set(client.id, client);
		socket.on('message', (data, binary) => this.onMessage(client, data, binary));
		socket.on('close', () => this.onDisconnect(client));
	}

	onMessage(client, data, binary) {
		if (!client.allow()) {
			client.error('rate_limited', 'Too many messages');
			return;
		}
		if (binary) {
			if (client.room) this.relayBinary(client, data);
			return;
		}
		let message;
		try {
			message = JSON.parse(data);
		} catch (e) {
			client.error('bad_json', 'Message is not valid JSON');
			return;
		}
		if (!isPlainObject(message) || typeof message.t !== 'string') {
			client.error('bad_message', 'Message needs a "t" field');
			return;
		}
		if (!client.helloed && message.t !== 'hello' && message.t !== 'ping') {
			client.error('no_hello', 'Send "hello" first', message.r);
			return;
		}
		const handler = this.handlers.get(message.t);
		if (!handler) {
			client.error('unknown_type', 'Unknown message type ' + message.t, message.r);
			return;
		}
		try {
			handler.call(this, client, message);
		} catch (e) {
			this.log('handler error', message.t, e);
			client.error('server_error', 'The server failed to handle ' + message.t, message.r);
		}
	}

	relayBinary(client, data) {
		const room = client.room;
		const header = Buffer.alloc(4);
		header.writeUInt32BE(client.id, 0);
		const packet = Buffer.concat([header, data]);
		for (const other of room.players.values()) {
			if (other !== client) other.socket.send(packet);
		}
	}

	onDisconnect(client) {
		if (!this.clients.has(client.id)) return;
		this.leaveRoom(client, 'disconnected');
		this.clients.delete(client.id);
	}

	checkHeartbeats() {
		const now = Date.now();
		for (const client of this.clients.values()) {
			if (now - client.socket.lastPong > this.options.heartbeatTimeout) client.socket.close(1001, 'Timed out');
			else client.socket.ping();
		}
	}

	joinRoom(client, room) {
		this.leaveRoom(client, 'switched');
		room.players.set(client.id, client);
		client.room = room;
		room.broadcast({ t: 'peer_join', player: client.info() }, client);
	}

	leaveRoom(client, reason = 'left') {
		const room = client.room;
		if (!room) return;
		room.players.delete(client.id);
		client.room = null;
		if (room.players.size === 0) {
			this.rooms.delete(room.id);
			return;
		}
		room.broadcast({ t: 'peer_leave', id: client.id, reason });
		if (room.host === client.id) {
			room.host = room.players.keys().next().value;
			room.broadcast({ t: 'host', id: room.host });
		}
	}

	stats() {
		return { version: VERSION, clients: this.clients.size, rooms: this.rooms.size, uptime: Math.round(process.uptime()) };
	}

	publicRooms() {
		return Array.from(this.rooms.values()).filter((room) => !room.private).map((room) => room.summary());
	}

	sendJson(response, status, body) {
		const text = JSON.stringify(body);
		response.writeHead(status, {
			'Content-Type': 'application/json; charset=utf-8',
			'Content-Length': Buffer.byteLength(text),
			'Access-Control-Allow-Origin': '*',
			'Access-Control-Allow-Headers': 'Content-Type',
			'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
		});
		response.end(text);
	}

	readBody(request, limit) {
		return new Promise((resolve, reject) => {
			let size = 0;
			const chunks = [];
			request.on('data', (chunk) => {
				size += chunk.length;
				if (size > limit) {
					reject(new Error('Body too large'));
					request.destroy();
					return;
				}
				chunks.push(chunk);
			});
			request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
			request.on('error', reject);
		});
	}

	async onRequest(request, response) {
		const url = new URL(request.url, 'http://localhost');
		const parts = url.pathname.split('/').filter((part) => part.length > 0);

		if (request.method === 'OPTIONS') {
			this.sendJson(response, 204, {});
			return;
		}

		try {
			if (request.method === 'GET' && (parts.length === 0 || parts[0] === 'health')) {
				this.sendJson(response, 200, Object.assign({ ok: true }, this.stats()));
			} else if (request.method === 'GET' && parts[0] === 'rooms' && parts.length === 1) {
				this.sendJson(response, 200, { rooms: this.publicRooms() });
			} else if (request.method === 'GET' && parts[0] === 'scores' && parts.length === 2) {
				const limit = Math.max(1, Math.min(100, Number(url.searchParams.get('limit')) || 10));
				this.sendJson(response, 200, { board: parts[1], scores: this.leaderboards.top(parts[1], limit) });
			} else if (request.method === 'POST' && parts[0] === 'scores' && parts.length === 2) {
				const body = JSON.parse(await this.readBody(request, 4096));
				const entry = this.leaderboards.submit(parts[1], body.name, body.score, body.data);
				if (!entry) this.sendJson(response, 400, { error: 'invalid score' });
				else this.sendJson(response, 200, { entry, rank: this.leaderboards.rank(parts[1], entry.name) });
			} else {
				this.sendJson(response, 404, { error: 'not found' });
			}
		} catch (e) {
			this.sendJson(response, 400, { error: e.message });
		}
	}

	registerDefaults() {
		this.on('hello', function (client, message) {
			const name = cleanText(message.name, this.options.maxNameLength);
			if (name) client.name = name;
			if (isPlainObject(message.data)) client.data = message.data;
			client.helloed = true;
			client.send({ t: 'welcome', r: message.r, id: client.id, name: client.name, version: VERSION, motd: this.options.motd, time: Date.now() });
		});

		this.on('ping', function (client, message) {
			client.send({ t: 'pong', r: message.r, time: message.time, server: Date.now() });
		});

		this.on('rename', function (client, message) {
			const name = cleanText(message.name, this.options.maxNameLength);
			if (!name) return client.error('bad_name', 'Invalid name', message.r);
			client.name = name;
			if (client.room) client.room.broadcast({ t: 'player', id: client.id, name: client.name, data: client.data });
		});

		this.on('list', function (client, message) {
			client.send({ t: 'rooms', r: message.r, rooms: this.publicRooms() });
		});

		this.on('create', function (client, message) {
			if (this.rooms.size >= this.options.maxRooms) return client.error('server_full', 'Too many rooms', message.r);
			const room = new Room(this, client, message);
			this.rooms.set(room.id, room);
			this.joinRoom(client, room);
			client.send({ t: 'joined', r: message.r, room: room.full(), you: client.id });
			this.log(`room ${room.id} created by ${client.name}`);
		});

		this.on('join', function (client, message) {
			const id = typeof message.id === 'string' ? message.id.toUpperCase() : '';
			const room = this.rooms.get(id);
			if (!room) return client.error('no_room', 'Room not found', message.r);
			if (room.players.has(client.id)) return client.send({ t: 'joined', r: message.r, room: room.full(), you: client.id });
			if (room.players.size >= room.maxPlayers) return client.error('room_full', 'Room is full', message.r);
			if (room.password !== null && room.password !== hashPassword(message.password)) return client.error('bad_password', 'Wrong password', message.r);
			if (room.started && room.meta.lockOnStart === true) return client.error('room_started', 'Game already started', message.r);
			this.joinRoom(client, room);
			client.send({ t: 'joined', r: message.r, room: room.full(), you: client.id });
		});

		this.on('quick', function (client, message) {
			const filter = isPlainObject(message.meta) ? message.meta : {};
			const match = Array.from(this.rooms.values()).find((room) => !room.private && !room.started && room.password === null && room.players.size < room.maxPlayers
				&& Object.keys(filter).every((key) => room.meta[key] === filter[key]));
			if (match) {
				this.joinRoom(client, match);
				client.send({ t: 'joined', r: message.r, room: match.full(), you: client.id });
				return;
			}
			const room = new Room(this, client, { name: message.name, maxPlayers: message.maxPlayers, meta: filter });
			this.rooms.set(room.id, room);
			this.joinRoom(client, room);
			client.send({ t: 'joined', r: message.r, room: room.full(), you: client.id });
		});

		this.on('leave', function (client, message) {
			this.leaveRoom(client, 'left');
			client.send({ t: 'left', r: message.r });
		});

		this.on('msg', function (client, message) {
			const room = client.room;
			if (!room) return client.error('no_room', 'Join a room first', message.r);
			const event = cleanText(message.event, 64);
			if (!event) return client.error('bad_event', 'Missing event name', message.r);
			const packet = { t: 'msg', from: client.id, event, data: message.data === undefined ? null : message.data };
			if (message.to !== undefined && message.to !== null) {
				const targets = Array.isArray(message.to) ? message.to : [message.to];
				const text = JSON.stringify(packet);
				for (const id of targets) {
					const target = room.players.get(Number(id));
					if (target) target.socket.send(text);
				}
			} else {
				room.broadcast(packet, message.echo === true ? undefined : client);
			}
		});

		this.on('chat', function (client, message) {
			const room = client.room;
			if (!room) return client.error('no_room', 'Join a room first', message.r);
			const text = cleanText(message.text, 300);
			if (!text) return;
			room.broadcast({ t: 'chat', from: client.id, name: client.name, text, time: Date.now() });
		});

		this.on('player', function (client, message) {
			if (!isPlainObject(message.data)) return client.error('bad_data', 'Player data must be an object', message.r);
			Object.assign(client.data, message.data);
			for (const key of Object.keys(message.data)) if (message.data[key] === null) delete client.data[key];
			if (client.room) client.room.broadcast({ t: 'player', id: client.id, name: client.name, data: client.data });
		});

		this.on('state', function (client, message) {
			const room = client.room;
			if (!room) return client.error('no_room', 'Join a room first', message.r);
			if (room.host !== client.id) return client.error('not_host', 'Only the host can change the room state', message.r);
			const key = cleanText(message.key, 64);
			if (!key) return client.error('bad_key', 'Missing key', message.r);
			if (message.value === null || message.value === undefined) delete room.state[key];
			else room.state[key] = message.value;
			room.broadcast({ t: 'state', key, value: message.value === undefined ? null : message.value });
		});

		this.on('meta', function (client, message) {
			const room = client.room;
			if (!room || room.host !== client.id) return client.error('not_host', 'Only the host can change the room', message.r);
			if (isPlainObject(message.meta)) room.meta = message.meta;
			if (typeof message.name === 'string') room.name = cleanText(message.name, 48) || room.name;
			if (typeof message.private === 'boolean') room.private = message.private;
			if (message.maxPlayers !== undefined) room.maxPlayers = Math.max(room.players.size, Math.min(this.options.maxPlayersPerRoom, Number(message.maxPlayers) || room.maxPlayers));
			if (message.password !== undefined) room.password = hashPassword(message.password);
			room.broadcast({ t: 'room', room: room.full() });
		});

		this.on('start', function (client, message) {
			const room = client.room;
			if (!room || room.host !== client.id) return client.error('not_host', 'Only the host can start', message.r);
			room.started = true;
			room.broadcast({ t: 'start', data: message.data === undefined ? null : message.data, at: Date.now() + (Number(message.delay) || 0) });
		});

		this.on('stop', function (client, message) {
			const room = client.room;
			if (!room || room.host !== client.id) return client.error('not_host', 'Only the host can stop', message.r);
			room.started = false;
			room.broadcast({ t: 'stop', data: message.data === undefined ? null : message.data });
		});

		this.on('kick', function (client, message) {
			const room = client.room;
			if (!room || room.host !== client.id) return client.error('not_host', 'Only the host can kick', message.r);
			const target = room.players.get(Number(message.id));
			if (!target || target === client) return client.error('no_player', 'Player not found', message.r);
			this.leaveRoom(target, 'kicked');
			target.send({ t: 'kicked', reason: cleanText(message.reason, 120) });
		});

		this.on('host', function (client, message) {
			const room = client.room;
			if (!room || room.host !== client.id) return client.error('not_host', 'Only the host can pass the host', message.r);
			const target = room.players.get(Number(message.id));
			if (!target) return client.error('no_player', 'Player not found', message.r);
			room.host = target.id;
			room.broadcast({ t: 'host', id: room.host });
		});

		this.on('score', function (client, message) {
			const entry = this.leaderboards.submit(message.board, client.name, message.score, message.data);
			if (!entry) return client.error('bad_score', 'Invalid score', message.r);
			client.send({ t: 'score', r: message.r, board: message.board, entry, rank: this.leaderboards.rank(message.board, client.name) });
		});

		this.on('scores', function (client, message) {
			const limit = Math.max(1, Math.min(100, Number(message.limit) || 10));
			client.send({ t: 'scores', r: message.r, board: message.board, scores: this.leaderboards.top(message.board, limit) });
		});
	}
}

function createServer(options) {
	return new NetworkServer(options);
}

module.exports = { createServer, NetworkServer, VERSION, randomCode, cleanText };
