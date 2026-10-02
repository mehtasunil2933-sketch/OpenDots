import { expect, it } from 'vitest';
import { createHmac } from 'node:crypto';
import { hardenSupervisorEnvironment } from '../deployment/computers/harden-supervisor.mjs';
import { remoteSupervisorDocker } from '../deployment/computers/remote-supervisor.mjs';

const upstream = `export function environmentFor(botId, env) {
  const computerToken = env.COMPUTER_TOKEN?.trim() || undefined;
  return [\`COMPUTER_BOT_ID=\${botId}\`, \`COMPUTER_TOKEN=\${computerToken}\`];
}`;
it('gives each child its own credential without forwarding the master', async () => {
  const module = await import(
    `data:text/javascript,${encodeURIComponent(hardenSupervisorEnvironment(upstream))}`
  );
  const master = 'fixture-master-only-for-this-test';
  const first = module.environmentFor('dot-a', { COMPUTER_TOKEN: master });
  const second = module.environmentFor('dot-b', { COMPUTER_TOKEN: master });
  expect(first[1]).toBe(
    `COMPUTER_TOKEN=${createHmac('sha256', master).update('opendots-computer:dot-a').digest('hex')}`,
  );
  expect(first[1]).not.toBe(second[1]);
  expect(first.join()).not.toContain(master);
  expect(() =>
    module.environmentFor('dot-a', { COMPUTER_TOKEN: 'short' }),
  ).toThrow();
});
it('refuses missing or ambiguous upstream patch targets', () => {
  expect(() => hardenSupervisorEnvironment('changed upstream')).toThrow(
    /contract changed/,
  );
  expect(() => hardenSupervisorEnvironment(upstream + upstream)).toThrow(
    /contract changed/,
  );
});

const dockerUpstream = `async function ensure(names, options, settled) {
  await docker.createContainer({
    HostConfig: hostConfig(names, options),
  });
  return {
    ...(options.network
      ? { url: \`http://\${names.container}:4100\` }
      : settled?.port
        ? { url: \`http://127.0.0.1:\${settled.port}\` }
        : {}),
  };
}`;
it('patches the supervisor for a separate computer host', () => {
  const patched = remoteSupervisorDocker(dockerUpstream);
  expect(patched).toContain(
    'HostConfig: await remoteHostConfig(hostConfig(names, options)),',
  );
  expect(patched).toContain('process.env.COMPUTER_PUBLIC_HOST');
  expect(patched).toContain('async function remoteHostConfig(config)');
  expect(patched).not.toContain('`http://127.0.0.1:${settled.port}`');
});
it('refuses to patch a changed supervisor docker contract', () => {
  expect(() => remoteSupervisorDocker('changed upstream')).toThrow(
    /contract changed/,
  );
  expect(() => remoteSupervisorDocker(dockerUpstream + dockerUpstream)).toThrow(
    /contract changed/,
  );
});
