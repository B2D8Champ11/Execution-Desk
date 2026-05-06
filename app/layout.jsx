import './globals.css'

export const metadata = {
  title: 'Execution Desk - Trade Journal',
  description: 'Professional trade journal for disciplined traders',
}

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
