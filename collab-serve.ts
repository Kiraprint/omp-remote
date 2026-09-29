#!/usr/bin/env bun
/**
 * omp collab: guest SPA + relay on ONE localhost origin.
 *
 * Speaks the exact relay contract of @oh-my-pi/collab-web scripts/local-relay.ts:
 * - `GET /r/<roomId>?role=host|guest` upgrades to a WebSocket.
 * - Host creates the room; second host -> close 4009; guest w/o room -> close 4004.
 * - Host binary frames: envelope peerId 0 broadcasts, peerId N targets guest N.
 * - Guest binary frames: first 4 bytes (u32 BE) rewritten to the sender's peerId.
 * - TEXT to host: {"t":"peer-joined","peer":N} / {"t":"peer-left","peer":N}.
 * - Host disconnect: {"t":"room-closed"} to guests, close 4001, drop room.
 *
 * Serving the SPA from the same origin keeps the phone on http://localhost:PORT,
 * which browsers treat as a secure context (WebCrypto works, no TLS cert needed).
 *
 * Usage: bun collab-serve.ts [--dist DIR] [--port 7466]
 */
import { join, normalize, sep } from "node:path";

const argv = Bun.argv.slice(2);
function flag(name: string): string | undefined {
	const inline = argv.find((a) => a.startsWith(`--${name}=`));
	if (inline) return inline.slice(name.length + 3);
	const i = argv.indexOf(`--${name}`);
	return i >= 0 ? argv[i + 1] : undefined;
}

const DIST = normalize(flag("dist") ?? join(import.meta.dir, "dist"));
const PORT = Number(flag("port") ?? 7466);
const HOST = flag("host") ?? "127.0.0.1";

const ROOM_PATH_RE = /^\/r\/([A-Za-z0-9_-]{10,64})$/;
const ENVELOPE_HEADER_LENGTH = 4;

interface SocketData {
	roomId: string;
	role: "host" | "guest";
	peerId: number;
}
type RelaySocket = Bun.ServerWebSocket<SocketData>;

interface Room {
	host: RelaySocket;
	guests: Map<number, RelaySocket>;
	nextPeerId: number;
}

const rooms = new Map<string, Room>();

function readPeerId(buf: Uint8Array): number | null {
	if (buf.byteLength < ENVELOPE_HEADER_LENGTH) return null;
	return new DataView(buf.buffer, buf.byteOffset, ENVELOPE_HEADER_LENGTH).getUint32(0, false);
}

function writePeerId(buf: Uint8Array, peerId: number): void {
	new DataView(buf.buffer, buf.byteOffset, ENVELOPE_HEADER_LENGTH).setUint32(0, peerId, false);
}

async function serveStatic(pathname: string): Promise<Response> {
	let rel: string;
	try {
		rel = decodeURIComponent(pathname);
	} catch {
		return new Response("bad request", { status: 400 });
	}
	if (rel.endsWith(sep) || rel.endsWith("/")) rel += "index.html";
	const full = normalize(join(DIST, rel));
	if (full !== DIST && !full.startsWith(DIST + sep)) return new Response("forbidden", { status: 403 });
	const file = Bun.file(full);
	if (await file.exists()) return new Response(file);
	// SPA fallback: unknown non-asset paths render the shell.
	const index = Bun.file(join(DIST, "index.html"));
	if (await index.exists()) {
		return new Response(index, { headers: { "content-type": "text/html; charset=utf-8" } });
	}
	return new Response("not found", { status: 404 });
}

function closeRoom(roomId: string, room: Room): void {
	rooms.delete(roomId);
	const closure = JSON.stringify({ t: "room-closed" });
	for (const guest of room.guests.values()) {
		guest.send(closure);
		guest.close(4001, "room closed");
	}
	room.guests.clear();
}

const server = Bun.serve({
	port: PORT,
	hostname: HOST,
	async fetch(req, srv) {
		const url = new URL(req.url);
		const match = ROOM_PATH_RE.exec(url.pathname);
		const role = url.searchParams.get("role");
		if (match && (role === "host" || role === "guest")) {
			const data: SocketData = { roomId: match[1]!, role, peerId: 0 };
			if (srv.upgrade(req, { data })) return undefined as unknown as Response;
			return new Response("websocket upgrade required", { status: 426 });
		}
		if (req.method !== "GET" && req.method !== "HEAD") {
			return new Response("method not allowed", { status: 405 });
		}
		return serveStatic(url.pathname);
	},
	websocket: {
		open(ws: RelaySocket): void {
			const { roomId, role } = ws.data;
			if (role === "host") {
				if (rooms.has(roomId)) {
					ws.close(4009, "a host is already connected for this room");
					return;
				}
				rooms.set(roomId, { host: ws, guests: new Map(), nextPeerId: 1 });
				console.log(`[relay] host opened room ${roomId}`);
				return;
			}
			const room = rooms.get(roomId);
			if (!room) {
				ws.close(4004, "no such room");
				return;
			}
			const peerId = room.nextPeerId++;
			ws.data.peerId = peerId;
			room.guests.set(peerId, ws);
			room.host.send(JSON.stringify({ t: "peer-joined", peer: peerId }));
			console.log(`[relay] guest ${peerId} joined room ${roomId}`);
		},
		message(ws: RelaySocket, message: string | Buffer): void {
			if (typeof message === "string") return; // clients never send TEXT
			const room = rooms.get(ws.data.roomId);
			if (!room) return;
			if (ws.data.role === "host") {
				const peerId = readPeerId(message);
				if (peerId === null) return;
				if (peerId === 0) {
					for (const guest of room.guests.values()) guest.send(message);
				} else {
					room.guests.get(peerId)?.send(message);
				}
				return;
			}
			if (message.byteLength < ENVELOPE_HEADER_LENGTH) return;
			writePeerId(message, ws.data.peerId);
			room.host.send(message);
		},
		close(ws: RelaySocket): void {
			const { roomId, role, peerId } = ws.data;
			const room = rooms.get(roomId);
			if (!room) return;
			if (role === "host") {
				// A duplicate host rejected with 4009 must not tear down the owner's room.
				if (room.host !== ws) return;
				console.log(`[relay] host closed room ${roomId}`);
				closeRoom(roomId, room);
				return;
			}
			if (room.guests.get(peerId) === ws && room.guests.delete(peerId)) {
				room.host.send(JSON.stringify({ t: "peer-left", peer: peerId }));
				console.log(`[relay] guest ${peerId} left room ${roomId}`);
			}
		},
	},
});

console.log(`collab-serve: SPA + relay on http://localhost:${server.port} (dist=${DIST})`);

const shutdown = (): void => {
	for (const [roomId, room] of rooms) closeRoom(roomId, room);
	server.stop(true);
	process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
