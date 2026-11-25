'use strict';

const fs = require('node:fs');
const path = require('node:path');

const MAX_ENTRIES = 1000;

class Leaderboards {
	constructor(file) {
		this.file = file;
		this.boards = new Map();
		this.dirty = false;
		this.timer = null;
		this.load();
	}

	load() {
		if (!this.file || !fs.existsSync(this.file)) return;
		try {
			const data = JSON.parse(fs.readFileSync(this.file, 'utf8'));
			for (const name of Object.keys(data)) if (Array.isArray(data[name])) this.boards.set(name, data[name]);
		} catch (e) {
			console.error('[network] could not read leaderboards', e.message);
		}
	}

	save() {
		if (!this.file || !this.dirty) return;
		this.dirty = false;
		const data = {};
		for (const [name, entries] of this.boards) data[name] = entries;
		fs.mkdirSync(path.dirname(path.resolve(this.file)), { recursive: true });
		const temp = this.file + '.tmp';
		fs.writeFileSync(temp, JSON.stringify(data));
		fs.renameSync(temp, this.file);
	}

	scheduleSave() {
		this.dirty = true;
		if (!this.file || this.timer) return;
		this.timer = setTimeout(() => {
			this.timer = null;
			this.save();
		}, 2000);
		this.timer.unref();
	}

	static validBoard(board) {
		return typeof board === 'string' && /^[A-Za-z0-9_\-.:]{1,64}$/.test(board);
	}

	submit(board, name, score, data) {
		if (!Leaderboards.validBoard(board)) return null;
		const value = Number(score);
		const player = typeof name === 'string' ? name.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 24) : '';
		if (!player || !Number.isFinite(value)) return null;

		const entries = this.boards.get(board) || [];
		const existing = entries.find((entry) => entry.name === player);
		const entry = { name: player, score: value, data: data !== null && typeof data === 'object' ? data : null, time: Date.now() };

		if (existing) {
			if (existing.score >= value) return existing;
			Object.assign(existing, entry);
		} else {
			entries.push(entry);
		}

		entries.sort((a, b) => b.score - a.score || a.time - b.time);
		if (entries.length > MAX_ENTRIES) entries.length = MAX_ENTRIES;
		this.boards.set(board, entries);
		this.scheduleSave();
		return existing || entry;
	}

	top(board, limit = 10) {
		if (!Leaderboards.validBoard(board)) return [];
		return (this.boards.get(board) || []).slice(0, limit);
	}

	rank(board, name) {
		const entries = this.boards.get(board) || [];
		const index = entries.findIndex((entry) => entry.name === name);
		return index < 0 ? -1 : index + 1;
	}
}

module.exports = { Leaderboards };
