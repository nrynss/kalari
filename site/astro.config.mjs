import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mdx from '@astrojs/mdx';

// Build for two homes from one source. Defaults ship the public Pages site,
// so a bare build never stamps localhost canonicals onto public pages.
// GitHub Pages: ASTRO_SITE=https://nrynss.github.io ASTRO_BASE=/kalari
// VM docs:      ASTRO_SITE=https://kalari.nryn.dev ASTRO_BASE=/docs
const site = process.env.ASTRO_SITE ?? 'https://nrynss.github.io';
const base = process.env.ASTRO_BASE ?? '/kalari';

export default defineConfig({
  site,
  base,
  integrations: [
    starlight({
      title: 'Kalari',
      description:
        'Rehearse every API upgrade in a contained arena, and learn from every fall.',
      logo: {
        src: './src/assets/kalari-mark.svg',
        alt: 'Kalari mark: stepped pit, coiled blade, staff strike',
      },
      favicon: '/favicon.svg',
      customCss: ['./src/styles/kalari.css'],
      sidebar: [
        { label: 'Start here', slug: 'start' },
        { label: 'Judges walkthrough', slug: 'judges' },
        { label: 'Architecture', slug: 'architecture' },
        { label: 'Vultr', slug: 'vultr' },
        { label: 'Containment', slug: 'containment' },
        { label: 'Install and configure', slug: 'run-it-yourself' },
        { label: 'MCP and tool commands', slug: 'mcp' },
        { label: 'Evidence and limits', slug: 'evidence' },
      ],
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/nrynss/kalari',
        },
      ],
    }),
    mdx(),
  ],
});
