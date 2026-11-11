import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { supabase } from '../supabase'

const getPosition = () =>
  new Promise<GeolocationPosition>((res, rej) =>
    navigator.geolocation.getCurrentPosition(res, rej, { enableHighAccuracy: true, timeout: 15000 }))

export default function Scan() {
  const { token } = useParams()
  const nav = useNavigate()
  const [name, setName] = useState('')
  const [mobile, setMobile] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  async function go(e: React.FormEvent) {
    e.preventDefault()
    setErr('')
    if (name.trim().length < 2) return setErr('Enter your name.')
    if (!/^\d{10}$/.test(mobile)) return setErr('Enter a 10-digit mobile number.')
    setBusy(true)
    try {
      const pos = await getPosition()
      if (!(await supabase.auth.getSession()).data.session) {
        const { error } = await supabase.auth.signInAnonymously()
        if (error) throw error
      }
      // Backend verifies token + distance; table number comes only from the server.
      const { data, error } = await supabase.rpc('start_table_session', {
        p_token: token, p_name: name, p_mobile: mobile,
        p_lat: pos.coords.latitude, p_lng: pos.coords.longitude,
      })
      if (error) throw error
      sessionStorage.setItem('table', String(data[0].table_number)) // display only
      nav('/menu')
    } catch (x: any) {
      setErr(x.code === 1 ? 'Location permission is required to order.' : x.message || 'Something went wrong.')
    } finally { setBusy(false) }
  }

  return (
    <form onSubmit={go} className="mx-auto max-w-sm space-y-3 p-6">
      <h1 className="text-2xl font-bold text-brand">Welcome</h1>
      <input className="input" placeholder="Your name" value={name} onChange={e => setName(e.target.value)} />
      <input className="input" placeholder="Mobile number" inputMode="numeric" maxLength={10}
        value={mobile} onChange={e => setMobile(e.target.value.replace(/\D/g, ''))} />
      {err && <p role="alert" className="text-sm text-red-600">{err}</p>}
      <button className="btn w-full" disabled={busy}>{busy ? 'Verifying…' : 'Continue'}</button>
    </form>
  )
}
