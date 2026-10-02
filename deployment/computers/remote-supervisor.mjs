import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

// Optional patch for running the supervisor and its computers on a separate host
// (for example a Zerops `computer` service) while the app runs elsewhere on a
// private network. Without COMPUTER_PORT_POOL the patched supervisor behaves
// exactly like upstream: loopback binding and an ephemeral port.
//
//   COMPUTER_PORT_POOL=41001-41010  fixed host ports to publish computers on
//   COMPUTER_PUBLISH_IP=0.0.0.0     interface to publish on (default 127.0.0.1)
//   COMPUTER_PUBLIC_HOST=computer   hostname the app uses to reach this host
//
// Fail closed if the pinned upstream contract changes.
const createTarget = 'HostConfig: hostConfig(names, options),';
const urlTarget = '? { url: `http://127.0.0.1:${settled.port}` }';

const helper = `
/* OpenDots remote-computer patch: publish computers on a fixed private port pool. */
async function remoteHostConfig(config) {
  const pool = process.env.COMPUTER_PORT_POOL?.trim();
  if (!pool || !config.PortBindings) return config;
  const match = /^(\\d+)-(\\d+)$/.exec(pool);
  if (!match || Number(match[1]) > Number(match[2]))
    throw new Error("COMPUTER_PORT_POOL must look like 41001-41010.");
  const used = new Set();
  for (const container of await docker.listContainers({ all: true })) {
    const info = await docker.getContainer(container.Id).inspect();
    for (const bindings of Object.values(info.HostConfig?.PortBindings ?? {}))
      for (const binding of bindings ?? [])
        if (binding.HostPort) used.add(Number(binding.HostPort));
  }
  for (let port = Number(match[1]); port <= Number(match[2]); port++) {
    if (used.has(port)) continue;
    return {
      ...config,
      PortBindings: {
        [COMPUTER_PORT]: [
          {
            HostIp: process.env.COMPUTER_PUBLISH_IP?.trim() || "127.0.0.1",
            HostPort: String(port),
          },
        ],
      },
    };
  }
  throw new Error(\`No free computer port left in COMPUTER_PORT_POOL \${pool}.\`);
}
`;

export function remoteSupervisorDocker(source) {
  for (const target of [createTarget, urlTarget])
    if (source.split(target).length !== 2)
      throw new Error(
        'Pinned OpenBot docker contract changed; review before building.',
      );
  return (
    source
      .replace(
        createTarget,
        'HostConfig: await remoteHostConfig(hostConfig(names, options)),',
      )
      .replace(
        urlTarget,
        '? { url: `http://${process.env.COMPUTER_PUBLIC_HOST?.trim() || "127.0.0.1"}:${settled.port}` }',
      ) + helper
  );
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const path = process.argv[2];
  if (!path) throw new Error('Pass the pinned supervisor docker.ts path.');
  await writeFile(path, remoteSupervisorDocker(await readFile(path, 'utf8')));
}
