(function () {
  'use strict';
  var el = document.getElementById('lca-data');
  var data = {};
  try { data = JSON.parse(el.textContent) || {}; } catch (e) { data = {}; }
  var agents = data.agents || [];
  var meta = document.getElementById('meta');
  var s = data.summary || {};
  meta.textContent = (s.detected || 0) + ' agents detected - ' + (s.rank || '') + ' - ' + (data.generatedAt || '');
  var app = document.getElementById('app');
  var list = document.createElement('ol');
  for (var i = 0; i < agents.length; i++) {
    var a = agents[i];
    var li = document.createElement('li');
    li.className = 'unit';
    var n = document.createElement('span');
    n.className = 'cmd';
    n.textContent = a.name + (a.version ? ' v' + a.version : '');
    var p = document.createElement('span');
    p.className = 'path';
    p.textContent = a.method + ' - ' + (a.source || '');
    li.appendChild(n);
    li.appendChild(p);
    list.appendChild(li);
  }
  app.appendChild(list);
})();
