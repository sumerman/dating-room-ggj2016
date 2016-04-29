var ws = null;

function send_ws(object) {
	ws.send(JSON.stringify(object));
}

$(document).ready(function() {
	var hash = window.location.hash.slice(1);
	var userid = hash ? hash : Math.random().toString(36);

	var ws_endpoint = "ws://"+window.location.hostname+":"+window.location.port+"/ws?user_id="+userid;
	if ("WebSocket" in window) {
		ws = new WebSocket(ws_endpoint);
		ws.onopen = function() {
			send_ws({type: 'ping'});
		};
		ws.onmessage = function (evt) { 
			var received_msg = evt.data;
			try {
				var updates = JSON.parse(received_msg);
				console.log(updates);
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
});
