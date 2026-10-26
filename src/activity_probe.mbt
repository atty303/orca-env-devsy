///|
fn activity_probe_source() -> String {
  let source =
    #|const fs = require('node:fs');
    #|const base = process.env.HOME + '/.local/share/orca-env-devsy/orca/current/resources/app.asar.unpacked/out';
    #|const { RuntimeClient } = require(base + '/cli/runtime/client.js');
    #|const errorCode = error => typeof error?.code === 'string' && /^[a-z_]{1,80}$/.test(error.code) ? error.code : 'observation_failed';
    #|function check(value, code) { if (!value) throw Object.assign(new Error(), { code }); }
    #|function emit(value) {
    #|  const output = JSON.stringify(value);
    #|  check(Buffer.byteLength(output) <= 4194304, 'activity_response_too_large');
    #|  process.stdout.write(output + '\n');
    #|}
    #|async function openChannel(config) {
    #|  check(typeof config.pairingCode === 'string' && config.pairingCode.length > 0, 'missing_native_access');
    #|  const { subscribeRemoteRuntimeRequest } = require(base + '/shared/remote-runtime-client.js');
    #|  const { STRUCTURED_AGENT_SESSION_RENDERER_CLIENT_CAPABILITIES: caps } = require(base + '/shared/structured-agent-session-renderer-client-capabilities.js');
    #|  check(Array.isArray(caps) && caps.length > 0, 'unsupported_native_capabilities');
    #|  const remote = new RuntimeClient(undefined, 5000, config.pairingCode, null).remote;
    #|  remote.endpoint = 'ws://127.0.0.1:47121';
    #|  let sub, timer, lost, settle, reject;
    #|  const sessions = new Map();
    #|  const snapshot = new Promise((resolve, fail) => { settle = resolve; reject = fail; });
    #|  snapshot.catch(() => {});
    #|  const fail = error => { if (lost) return; lost = error ?? Object.assign(new Error(), { code: 'native_connection_closed' }); reject(lost); sub?.close(); };
    #|  timer = setTimeout(() => fail(Object.assign(new Error(), { code: 'native_snapshot_timeout' })), 5000);
    #|  const request = async (method, params) => {
    #|    if (lost) throw lost;
    #|    const response = await sub.sendRequest(method, params, 5000);
    #|    check(response.ok, errorCode(response.error));
    #|    return response;
    #|  };
    #|  try {
    #|    sub = await subscribeRemoteRuntimeRequest(remote, 'agentSession.subscribeStatus', undefined, 5000, {
    #|      onResponse(response) {
    #|        if (lost) return;
    #|        try {
    #|          check(response.ok, errorCode(response.error));
    #|          const event = response.result;
    #|          if (event?.type === 'snapshot' && !Object.hasOwn(event, 'namingActiveSessionIds')) {
    #|            check(Array.isArray(event.sessions) && event.sessions.length <= 1000, 'invalid_native_snapshot');
    #|            for (const s of event.sessions) sessions.set(s.sessionId, { sessionId: s.sessionId, workspaceId: s.workspaceId, agent: s.agent });
    #|            settle();
    #|          } else if (event?.type === 'status') {
    #|            const s = event.session;
    #|            check(s && typeof s.sessionId === 'string', 'invalid_native_status');
    #|            sessions.set(s.sessionId, { sessionId: s.sessionId, workspaceId: s.workspaceId, agent: s.agent });
    #|            check(sessions.size <= 1000, 'incomplete_native_listing');
    #|          }
    #|        } catch (error) { fail(error); }
    #|      },
    #|      onError: fail,
    #|      onClose: () => fail(Object.assign(new Error(), { code: 'native_connection_closed' })),
    #|    }, { clientCapabilities: caps });
    #|    check(typeof sub.sendRequest === 'function', 'unsupported_shared_requests');
    #|    const restored = await request('session.tabs.listAll');
    #|    check(restored.result?.authoritative === true, 'native_restoration_unconfirmed');
    #|    await snapshot;
    #|    return { request, sessions: () => { if (lost) throw lost; check(sessions.size <= 1000, 'incomplete_native_listing'); return [...sessions.values()]; }, close: () => sub.close() };
    #|  } catch (error) { sub?.close(); throw error; }
    #|  finally { clearTimeout(timer); }
    #|}
    #|async function observe(call, native, nativeError) {
    #|  const result = { schemaVersion: 1, observedAt: new Date().toISOString(), terminals: [], chats: [], errors: [] };
    #|  try {
    #|  const status = await call('status.get');
    #|  result.orcaVersion = status.appVersion;
    #|  check(status.graphStatus === 'ready', 'graph_not_ready');
    #|  const listed = await call('terminal.list', { limit: 10000, requireFreshPtyLiveness: true, includeVisualLayouts: false });
    #|  const ps = await call('worktree.ps', { limit: 10000 });
    #|  check(Array.isArray(listed.terminals) && listed.truncated === false && Array.isArray(ps.worktrees) && ps.truncated === false, 'incomplete_listing');
    #|  const agents = ps.worktrees.flatMap(w => w.agents.map(a => ({ ...a, worktreeId: w.worktreeId })));
    #|  for (const terminal of listed.terminals) {
    #|    const row = { handle: terminal.handle, worktreeId: terminal.worktreeId, connected: terminal.connected, observedAt: new Date().toISOString() };
    #|    result.terminals.push(row);
    #|    try {
    #|      const p = (await call('terminal.inspectProcess', { terminal: terminal.handle, scanChildProcesses: true })).process;
    #|      const evidence = p.foregroundProcessEvidence;
    #|      row.foregroundProcess = p.foregroundProcess;
    #|      row.hasChildProcesses = p.hasChildProcesses;
    #|      row.processEvidence = evidence ? { verdict: evidence.verdict, capturedAgeMs: evidence.capturedAgeMs, ptyIncarnationId: evidence.ptyIncarnationId, observationEpoch: evidence.observationEpoch } : null;
    #|      check(row.connected === true && evidence?.verdict === 'live' && Number.isFinite(evidence.capturedAgeMs) && evidence.capturedAgeMs <= 5000 && typeof p.hasChildProcesses === 'boolean', 'unverifiable_process');
    #|      const agent = agents.find(a => a.worktreeId === terminal.worktreeId && a.paneKey === terminal.tabId + ':' + terminal.leafId);
    #|      if (agent) {
    #|        row.agent = { type: agent.agentType, state: agent.state, programState: agent.programStatus?.state ?? null, stateStartedAt: agent.stateStartedAt, updatedAt: agent.updatedAt };
    #|        if (['working', 'waiting', 'blocked', 'monitoring'].includes(agent.state) || ['working', 'blocked'].includes(agent.programStatus?.state) || p.hasChildProcesses || (p.foregroundProcess !== null && p.foregroundProcess !== agent.agentType)) row.activity = 'active';
    #|        else if (agent.state === 'done' && agent.programStatus?.state === 'idle') row.activity = 'idle';
    #|        else row.activity = 'unknown';
    #|      } else if (p.foregroundProcess !== null || p.hasChildProcesses) row.activity = 'active';
    #|      else if (terminal.agentIdentity) row.activity = 'unknown';
    #|      else row.activity = 'idle';
    #|    } catch (error) { row.activity = 'unknown'; row.error = errorCode(error); }
    #|  }
    #|  for (const workspace of ps.worktrees) {
    #|    if (workspace.unverifiableTerminalCount !== 0) result.errors.push({ source: 'terminal', code: 'unverifiable_terminal' });
    #|    for (const a of workspace.agents) {
    #|      if (!a.paneKey?.startsWith('structured-agent-session-') && (a.state !== 'done' || a.programStatus?.state !== 'idle')) {
    #|        result.terminals.push({ worktreeId: workspace.worktreeId, agent: { type: a.agentType, state: a.state, programState: a.programStatus?.state ?? null }, activity: ['working', 'waiting', 'blocked', 'monitoring'].includes(a.state) || ['working', 'blocked'].includes(a.programStatus?.state) ? 'active' : 'unknown' });
    #|      }
    #|    }
    #|  }
    #|
    #|    try {
    #|      if (nativeError) throw nativeError;
    #|      const sessions = native.sessions();
    #|      for (const session of sessions) {
    #|        const row = { sessionId: session.sessionId, workspaceId: session.workspaceId, agent: session.agent, observedAt: new Date().toISOString() };
    #|        result.chats.push(row);
    #|        try {
    #|          const response = await native.request('agentSession.history', { sessionId: session.sessionId, direction: 'tail', limit: 1 });
    #|          check(response.ok, 'native_history_failed');
    #|          const page = response.result.page;
    #|          check(typeof page.working === 'boolean' && Array.isArray(page.queuedMessages) && Array.isArray(page.actionablePromptIds), 'incomplete_native_history');
    #|          const tasks = page.backgroundTasks;
    #|          check(tasks === undefined || tasks === null || Array.isArray(tasks.tasks), 'incomplete_background_tasks');
    #|          row.working = page.working;
    #|          row.queuedMessages = page.queuedMessages.length;
    #|          row.actionablePrompts = page.actionablePromptIds.length;
    #|          row.backgroundTasks = tasks?.tasks?.length ?? 0;
    #|          row.activity = row.working || row.queuedMessages || row.actionablePrompts || row.backgroundTasks ? 'active' : 'idle';
    #|        } catch (error) { row.activity = 'unknown'; row.error = errorCode(error); }
    #|      }
    #|
    #|    } catch (error) { result.errors.push({ source: 'native-chat', code: errorCode(error) }); }
    #|  } catch (error) { result.errors.push({ source: 'orca', code: errorCode(error) }); }
    #|  const all = [...result.terminals, ...result.chats];
    #|  result.activity = all.some(row => row.activity === 'active') ? 'active' : result.errors.length || all.some(row => row.activity !== 'idle') ? 'unknown' : 'idle';
    #|  return result;
    #|}
    #|async function main() {
    #|  let channel;
    #|  const close = () => channel?.close();
    #|  process.once?.('SIGTERM', () => { close(); process.exit(0); });
    #|  process.stdin?.once('end', close);
    #|  try {
    #|    const config = JSON.parse(fs.readFileSync(0, 'utf8'));
    #|    channel = await openChannel(config);
    #|    emit(await observe(async (m, p) => (await channel.request(m, p)).result, channel));
    #|  } finally { close(); }
    #|}
    #|main().catch(error => { emit({ schemaVersion: 1, activity: 'unknown', errors: [{ source: 'observer', code: errorCode(error) }] }); process.exitCode = 1; });
  source
}
