import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Lantern VNC feedback",
  description: "Lantern VNC customer feedback service",
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className="antialiased">{children}</body>
    </html>
  );
}
