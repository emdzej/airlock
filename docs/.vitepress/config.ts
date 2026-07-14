import { defineConfig } from 'vitepress'

// Site config for airlock.emdzej.pl.
//
// Custom domain lives at docs/public/CNAME. Since Pages serves the
// site off a root domain, base stays '/' and no baseURL rewriting is
// needed. Anchors in the sidebar point at H2s inside the existing
// guide.md / install.md so we don't have to shard those big pages
// into subpages yet.

export default defineConfig({
  title: 'Airlock',
  titleTemplate: ':title · Airlock',
  description:
    'Network card reader appliance for the Raspberry Pi 4. Plug a USB drive, share it over SMB and HTTP within seconds.',

  cleanUrls: true,
  lastUpdated: true,
  metaChunk: true,

  head: [
    ['meta', { name: 'theme-color', content: '#3aa675' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:site_name', content: 'Airlock' }],
    ['meta', { property: 'og:title', content: 'Airlock — mass storage over the network' }],
    ['meta', { property: 'og:description', content: 'Network card reader appliance for the Raspberry Pi 4.' }],
    ['meta', { property: 'og:url', content: 'https://airlock.emdzej.pl/' }],
  ],

  sitemap: {
    hostname: 'https://airlock.emdzej.pl',
  },

  themeConfig: {
    siteTitle: 'Airlock',

    nav: [
      { text: 'Overview', link: '/overview' },
      { text: 'Install', link: '/install' },
      { text: 'User guide', link: '/guide' },
      { text: 'Companion (macOS)', link: '/companion' },
      {
        text: 'Reference',
        items: [
          { text: 'Changelog', link: 'https://github.com/emdzej/airlock/blob/main/CHANGELOG.md' },
          { text: 'Source (GitHub)', link: 'https://github.com/emdzej/airlock' },
          { text: 'License (MIT)', link: 'https://github.com/emdzej/airlock/blob/main/LICENSE' },
        ],
      },
    ],

    sidebar: [
      {
        text: 'Introduction',
        collapsed: false,
        items: [
          { text: 'What is Airlock?', link: '/overview' },
          { text: 'Installation', link: '/install' },
        ],
      },
      {
        text: 'Using Airlock',
        collapsed: false,
        items: [
          { text: 'User guide', link: '/guide' },
          { text: 'Web UI', link: '/guide#the-web-ui' },
          { text: 'SMB from Finder/Explorer', link: '/guide#smb' },
          { text: 'macOS companion app', link: '/companion' },
          { text: 'Format · flash · dump · fsck', link: '/guide#device-tools' },
          { text: 'Physical eject button', link: '/guide#physical-eject-button' },
        ],
      },
      {
        text: 'Reference',
        collapsed: false,
        items: [
          {
            text: 'Changelog',
            link: 'https://github.com/emdzej/airlock/blob/main/CHANGELOG.md',
          },
          {
            text: 'Source on GitHub',
            link: 'https://github.com/emdzej/airlock',
          },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/emdzej/airlock' },
    ],

    editLink: {
      pattern: 'https://github.com/emdzej/airlock/edit/main/docs/:path',
      text: 'Suggest an edit on GitHub',
    },

    search: {
      provider: 'local',
    },

    footer: {
      message:
        'Released under the <a href="https://github.com/emdzej/airlock/blob/main/LICENSE">MIT License</a>.',
      copyright: 'Copyright © 2026 emdzej',
    },

    outline: {
      level: [2, 3],
    },
  },
})
