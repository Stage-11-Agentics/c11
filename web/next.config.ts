import "./app/env";
import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";

const withNextIntl = createNextIntlPlugin("./i18n/request.ts");

const nextConfig: NextConfig = {
  skipTrailingSlashRedirect: true,
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "github.com",
        pathname: "/*.png",
      },
    ],
  },
  async redirects() {
    return [
      {
        source: "/blog/introducing-cmux",
        destination: "/blog/introducing-c11",
        permanent: true,
      },
      {
        source: "/:locale/blog/introducing-cmux",
        destination: "/:locale/blog/introducing-c11",
        permanent: true,
      },
    ];
  },
};

export default withNextIntl(nextConfig);
