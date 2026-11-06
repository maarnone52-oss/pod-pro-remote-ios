// POD Pro Remote (iOS): fornisce alla pagina l'interfaccia Web MIDI usando il MIDI nativo dell'app.
(function () {
  "use strict";
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.midi;
  if (!bridge) return;
  function post(msg) { try { bridge.postMessage(msg); } catch (e) {} }

  function Port(type, id, name) {
    this.type = type; this.id = id; this.name = name;
    this.manufacturer = ""; this.state = "connected"; this.connection = "open";
    this.onmidimessage = null;
  }
  Port.prototype.send = function (data) { post({ cmd: "send", id: this.id, data: Array.from(data) }); };

  var access = { inputs: new Map(), outputs: new Map(), sysexEnabled: true, onstatechange: null };
  var ready = false, resolveReady;
  var readyPromise = new Promise(function (r) { resolveReady = r; });

  function sync(map, list, type) {
    var keep = new Set(list.map(function (p) { return p.id; }));
    Array.from(map.keys()).forEach(function (k) { if (!keep.has(k)) map.delete(k); });
    list.forEach(function (p) {
      if (map.has(p.id)) map.get(p.id).name = p.name;
      else map.set(p.id, new Port(type, p.id, p.name));
    });
  }

  window.__podMIDI = {
    receive: function (m) {
      if (m.type === "ports") {
        sync(access.inputs, m.inputs || [], "input");
        sync(access.outputs, m.outputs || [], "output");
        if (!ready) { ready = true; resolveReady(access); }
        else if (typeof access.onstatechange === "function") access.onstatechange({ port: null });
      } else if (m.type === "msg") {
        var port = access.inputs.get(m.id);
        if (port && typeof port.onmidimessage === "function")
          port.onmidimessage({ data: new Uint8Array(m.data), timeStamp: performance.now(), target: port });
      }
    }
  };

  navigator.requestMIDIAccess = function () { post({ cmd: "init" }); return readyPromise; };

  // Backup ed esportazione: i file vengono passati all'app, che apre "Salva in File" / Condividi
  var nativeClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (this.hasAttribute("download") && /^(blob|data):/.test(this.href)) {
      var name = this.getAttribute("download") || "file";
      fetch(this.href)
        .then(function (r) { return r.blob(); })
        .then(function (b) {
          return new Promise(function (res) { var fr = new FileReader(); fr.onload = function () { res(fr.result); }; fr.readAsDataURL(b); });
        })
        .then(function (url) { post({ cmd: "save", name: name, base64: String(url).split(",")[1] || "" }); });
      return;
    }
    return nativeClick.call(this);
  };

  window.podNative = { bluetooth: function () { post({ cmd: "bluetooth" }); } };
})();
