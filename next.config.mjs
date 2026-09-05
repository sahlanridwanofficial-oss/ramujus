/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: '**.supabase.co',
      },
    ],
  },
};

let exportConfig = nextConfig;

try {
  const withPWAInit = (await import("@ducanh2912/next-pwa")).default;
  const withPWA = withPWAInit({
    dest: "public",
    disable: process.env.NODE_ENV === "development",
    register: true,
    skipWaiting: true,
  });
  exportConfig = withPWA(nextConfig);
} catch {
  exportConfig = nextConfig;
}

export default exportConfig;
