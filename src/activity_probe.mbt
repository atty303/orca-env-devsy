///|
fn activity_probe_source() -> String {
  let source =
    #|const fs = require('node:fs');
    #|const base = process.env.HOME + '/.local/share/orca-env-devsy/orca/current/resources/app.asar.unpacked/out';
    #|const { RuntimeClient } = require(base + '/cli/runtime/client.js');
    #|const config = JSON.parse(fs.readFileSync(0, 'utf8'));
    #|const client = new RuntimeClient(undefined, 5000, null, null);
    #|const result = { schemaVersion: 1, observedAt: new Date().toISOString(), terminals: [], chats: [], errors: [] };
    #|const errorCode = error => typeof error.code === 'string' && /^[a-z_]{1,80}$/.test(error.code) ? error.code : 'observation_failed';
    #|function check(value, message) { if (!value) throw Object.assign(new Error(), { code: message }); }
    #|async function call(method, params) { return (await client.call(method, params)).result; }
    #|async function observe() {
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
    #|  try {
    #|    check(typeof config.pairingCode === 'string' && config.pairingCode.length > 0, 'missing_native_access');
    #|    const { subscribeRemoteRuntimeRequest, sendRemoteRuntimeRequest } = require(base + '/shared/remote-runtime-client.js');
    #|    const remote = new RuntimeClient(undefined, 5000, config.pairingCode, null).remote;
    #|    remote.endpoint = 'ws://127.0.0.1:47121';
    #|    const { STRUCTURED_AGENT_SESSION_RENDERER_CLIENT_CAPABILITIES: caps } = require(base + '/shared/structured-agent-session-renderer-client-capabilities.js');
    #|    check(Array.isArray(caps) && caps.length > 0, 'unsupported_native_capabilities');
    #|    const restored = await sendRemoteRuntimeRequest(remote, 'session.tabs.listAll', undefined, 5000, undefined, undefined, caps);
    #|    check(restored.ok && restored.result?.authoritative === true, 'native_restoration_unconfirmed');
    #|    let sub, timer;
    #|    let settle, reject;
    #|    const snapshot = new Promise((resolve, fail) => { settle = resolve; reject = fail; });
    #|    timer = setTimeout(() => reject(Object.assign(new Error(), { code: 'native_snapshot_timeout' })), 5000);
    #|    try {
    #|      sub = await subscribeRemoteRuntimeRequest(remote, 'agentSession.subscribeStatus', undefined, 5000, {
    #|        onResponse(response) {
    #|          if (!response.ok) { reject(Object.assign(new Error(), { code: response.error?.code })); return; }
    #|          const event = response.result;
    #|          if (event?.type === 'snapshot' && !Object.hasOwn(event, 'namingActiveSessionIds')) {
    #|            if (!Array.isArray(event.sessions)) { reject(Object.assign(new Error(), { code: 'invalid_native_snapshot' })); return; }
    #|            settle(event.sessions);
    #|          }
    #|        },
    #|        onError: reject,
    #|      }, { clientCapabilities: caps });
    #|      const sessions = await snapshot;
    #|      check(Array.isArray(sessions), 'native_restoration_unconfirmed');
    #|      check(sessions.length <= 1000, 'incomplete_native_listing');
    #|      for (const session of sessions) {
    #|        const row = { sessionId: session.sessionId, workspaceId: session.workspaceId, agent: session.agent, observedAt: new Date().toISOString() };
    #|        result.chats.push(row);
    #|        try {
    #|          const response = await sendRemoteRuntimeRequest(remote, 'agentSession.history', { sessionId: session.sessionId, direction: 'tail', limit: 1 }, 5000, undefined, undefined, caps);
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
    #|    } finally { clearTimeout(timer); sub?.close(); }
    #|  } catch (error) { result.errors.push({ source: 'native-chat', code: errorCode(error) }); }
    #|}
    #|observe().catch(error => result.errors.push({ source: 'orca', code: errorCode(error) })).finally(() => {
    #|  const all = [...result.terminals, ...result.chats];
    #|  result.activity = all.some(row => row.activity === 'active') ? 'active' : result.errors.length || all.some(row => row.activity !== 'idle') ? 'unknown' : 'idle';
    #|  process.stdout.write(JSON.stringify(result));
    #|});
  source
}
