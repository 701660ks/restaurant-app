import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter, Route, Routes } from 'react-router-dom'
import Scan from './pages/Scan'
import Menu from './pages/Menu'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <Routes>
        <Route path="/t/:token" element={<Scan />} />
        <Route path="/menu" element={<Menu />} />
        <Route path="*" element={<p className="p-6">Scan the QR code on your table to order.</p>} />
      </Routes>
    </BrowserRouter>
  </React.StrictMode>,
)
