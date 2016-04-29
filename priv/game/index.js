var ws = null;

function send_ws(object) {
	ws.send(JSON.stringify(object));
}

function spawnPlayer(name) {
	var code = '<div class="player" id="'+name+'">'+name+'<div>';
	if ($('#players #' + name).length === 0) {
		$('#players').append(code);
	}
	return document.getElementById(name);
}

function despawnPlayer(name) {
	var element = document.getElementById(name);
	element.parentNode.removeChild(element);
}

function setPlayerPos(elem, pos) {
	var css = {}, w = $(elem).width(), h = $(elem).height();
	if (pos.x !== undefined)
		css.left = pos.x - w/2;
	if (pos.y !== undefined)
		css.top = pos.y - h/2;

	$(elem).css(css);
}

function Player(id) {
	this.x = 0;	   
	this.y = 0;
	this.id = id;
	this._elem = spawnPlayer(id);
	this.set = function(upd) {
		if (upd.x !== undefined)
			this.x = upd.x;
		if (upd.y !== undefined)
			this.y = upd.y;
		setPlayerPos(this._elem, upd);
		return this;
	};
	this.updPos = function(upd) {
		if (upd.x !== undefined)
			this.x += upd.x;
		if (upd.y !== undefined)
			this.y += upd.y;
		setPlayerPos(this._elem, {x: this.x, y: this.y});
		return this;
	};
}

$(document).ready(function() {
	var players = {};
	function addPlayer(id) {
		if (players[id] === undefined) {
			players[id] = new Player(id);
		}
		return players[id];
	};
	function removePlayer(id) {
		delete players[id];
		despawnPlayer(id);
	};

	var hub = 'game1';
	var stream = 'field';
	var last_seen = null;
	var hash = window.location.hash.slice(1);
	var userid = hash ? hash : Math.random().toString(36);
	var player = addPlayer(userid);

	var ws_endpoint = "ws://"+window.location.hostname+":"+window.location.port+"/ws?user_id="+userid;
	if ("WebSocket" in window) {
		ws = new WebSocket(ws_endpoint);
		ws.onopen = function() {
			// TODO on disconnect message
			send_ws({type: 'declare_hub', hub: hub, default_streams: [stream]});
			send_ws({type: 'send_on_leave', hub: hub, stream: stream, payload: null })
		};
		ws.onmessage = function (evt) { 
			var received_msg = evt.data;
			try {
				var update = JSON.parse(received_msg);
				console.log(update);
				if (update['type'] == 'stream_joined' && update['hub'] == hub) {
					last_seen = update['last_seen']
					players_st = (update['stash'] || {})['players']
					for (var player_i in players_st) {
						if (players_st[player_i]) {
							addPlayer(player_i);
							var upd = {
								x: players_st[player_i].x,
								y: players_st[player_i].y
							};
							players[player_i].set(upd);
						}
					}
					send_ws({type: 'send', hub: hub, stream: stream, payload: {x: player.x, y: player.y}})
				}
				if (update['type'] == 'update' && update['hub'] == hub) {
					last_seen = update['id'];
					var player_i = update['user_id'];
					if(player_i !== userid) {
						if(players[player_i] === undefined) {
							addPlayer(player_i);
						}
						if(update['payload'] === null) { removePlayer(player_i); }
						else { players[player_i].set(update['payload']); }
					}
					var stash = {players: players};
					send_ws({type: 'snapshot', hub: hub, stream: stream, last_seen: last_seen, stash: stash});
				}
				if (update['type'] == 'initialized' && last_seen == null) {
					send_ws({type: 'switch_hubs', join_hubs: [hub]});
				}
			}
			catch (e) {
				console.log("Error" + e + ". Upon: " + evt);
			}
		};
		ws.onclose = function() { 
			window.location.reload();
		};
	}
	else {
		alert("WebSocket is NOT supported by your Browser!");
	}

	var a = 1;
	$(document).keydown(function(e) {
		if (a < 3.0) a *= 1.1;
		var d = 5*a;
		var upd = null;
		if (e.which === 37) upd = {x:-d};
		if (e.which === 39) upd = {x: d};
		if (e.which === 38) upd = {y:-d};
		if (e.which === 40) upd = {y: d};
		if (upd) {
			player.updPos(upd)
			send_ws({type: 'send', hub: hub, stream: stream, payload: {x: player.x, y: player.y} })
		}
	});
	$(document).keyup(function(e) { a=1; });
});
