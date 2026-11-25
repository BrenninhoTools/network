'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { createServer } = require('../src/server');

function connect(port) {
	return new Promise((resolve, reject) => {
		const socket = new WebSocket(`ws://127.0.0.1:${port}/`);
		const queue = [];
		const waiters = [];
		socket.binaryType = 'arraybuffer';
		socket.addEventListener('message', (event) => {
			const message = typeof event.data === 'string' ? JSON.parse(event.data) : { binary: Buffer.from(event.data) };
			const index = waiters.findIndex((waiter) => waiter.match(message));
			if (index >= 0) waiters.splice(index, 1)[0].resolve(message);
			else queue.push(message);
		});
		socket.addEventListener('open', () => resolve({
			socket,
			send: (message) => socket.send(JSON.stringify(message)),
			wait: (type) => new Promise((done, fail) => {
				const match = (message) => type === 'binary' ? message.binary !== undefined : message.t === type;
				const index = queue.findIndex(match);
				if (index >= 0) return done(queue.splice(index, 1)[0]);
				const timer = setTimeout(() => fail(new Error('timeout waiting for ' + type)), 2000);
				waiters.push({ match, resolve: (message) => { clearTimeout(timer); done(message); } });
			}),
			close: () => socket.close()
		}));
		socket.addEventListener('error', reject);
	});
}

test('rooms, relay, state, chat, host and leaderboards', async () => {
	const server = createServer({ port: 0, log: false });
	const { port } = await server.listen(0, '127.0.0.1');

	const a = await connect(port);
	const b = await connect(port);

	a.send({ t: 'list' });
	assert.strictEqual((await a.wait('error')).code, 'no_hello');

	a.send({ t: 'hello', name: 'Alice', r: 1 });
	const welcome = await a.wait('welcome');
	assert.strictEqual(welcome.name, 'Alice');
	assert.strictEqual(welcome.r, 1);
	b.send({ t: 'hello', name: 'Bob' });
	await b.wait('welcome');

	a.send({ t: 'create', name: 'Week 1', maxPlayers: 2, password: 'pw', meta: { song: 'bopeebo' } });
	const created = await a.wait('joined');
	assert.strictEqual(created.room.name, 'Week 1');
	assert.strictEqual(created.room.host, welcome.id);

	b.send({ t: 'list' });
	const rooms = await b.wait('rooms');
	assert.strictEqual(rooms.rooms.length, 1);
	assert.strictEqual(rooms.rooms[0].locked, true);

	b.send({ t: 'join', id: created.room.id.toLowerCase(), password: 'nope' });
	assert.strictEqual((await b.wait('error')).code, 'bad_password');
	b.send({ t: 'join', id: created.room.id, password: 'pw' });
	const joined = await b.wait('joined');
	assert.strictEqual(joined.room.players.length, 2);
	assert.strictEqual((await a.wait('peer_join')).player.name, 'Bob');

	b.send({ t: 'msg', event: 'note', data: { lane: 2 } });
	const note = await a.wait('msg');
	assert.deepStrictEqual(note.data, { lane: 2 });
	assert.strictEqual(note.from, joined.you);

	b.send({ t: 'state', key: 'song', value: 'x' });
	assert.strictEqual((await b.wait('error')).code, 'not_host');
	a.send({ t: 'state', key: 'song', value: 'fresh' });
	assert.strictEqual((await b.wait('state')).value, 'fresh');

	b.send({ t: 'player', data: { ready: true } });
	assert.strictEqual((await a.wait('player')).data.ready, true);

	a.send({ t: 'chat', text: 'gl hf' });
	assert.strictEqual((await b.wait('chat')).text, 'gl hf');

	b.socket.send(new Uint8Array([1, 2, 3]));
	const binary = await a.wait('binary');
	assert.strictEqual(binary.binary.readUInt32BE(0), joined.you);
	assert.deepStrictEqual([...binary.binary.subarray(4)], [1, 2, 3]);

	a.send({ t: 'ping', time: 5 });
	assert.strictEqual((await a.wait('pong')).time, 5);

	a.send({ t: 'score', board: 'week1', score: 1000 });
	assert.strictEqual((await a.wait('score')).rank, 1);
	b.send({ t: 'score', board: 'week1', score: 2000 });
	await b.wait('score');
	a.send({ t: 'scores', board: 'week1' });
	const scores = await a.wait('scores');
	assert.deepStrictEqual(scores.scores.map((entry) => entry.name), ['Bob', 'Alice']);

	const response = await fetch(`http://127.0.0.1:${port}/scores/week1?limit=1`);
	assert.strictEqual((await response.json()).scores[0].name, 'Bob');
	const health = await (await fetch(`http://127.0.0.1:${port}/health`)).json();
	assert.strictEqual(health.rooms, 1);

	a.close();
	assert.strictEqual((await b.wait('host')).id, joined.you);
	b.close();
	await server.close();
});

test('large fragmented-size messages and limits', async () => {
	const server = createServer({ port: 0, log: false, maxPayload: 1024 });
	const { port } = await server.listen(0, '127.0.0.1');
	const a = await connect(port);
	a.send({ t: 'hello', name: 'x'.repeat(100) });
	assert.strictEqual((await a.wait('welcome')).name.length, 24);
	const closed = new Promise((resolve) => a.socket.addEventListener('close', (event) => resolve(event.code)));
	a.socket.send('y'.repeat(5000));
	assert.strictEqual(await closed, 1009);
	await server.close();
});
