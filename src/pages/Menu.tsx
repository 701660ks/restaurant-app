import { useEffect, useMemo, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { money, supabase } from '../supabase'

type Food = { id: string; name: string; description: string | null; image_url: string | null; price: number;
  is_veg: boolean; discount_percent: number; category_id: string | null; orders_count: number }
type Cat = { id: string; name: string }
const STEPS = ['pending', 'accepted', 'preparing', 'ready', 'served', 'completed']
const LABEL: Record<string, string> = { pending: 'Order placed', accepted: 'Accepted', preparing: 'Preparing',
  ready: 'Ready', served: 'Served', completed: 'Completed', cancelled: 'Cancelled' }

export default function Menu() {
  const table = sessionStorage.getItem('table')
  const [foods, setFoods] = useState<Food[]>([])
  const [cats, setCats] = useState<Cat[]>([])
  const [cat, setCat] = useState('')
  const [q, setQ] = useState('')
  const [cart, setCart] = useState<Record<string, number>>({})
  const [method, setMethod] = useState<'cash' | 'upi'>('cash')
  const [tax, setTax] = useState({ tax: 0, service: 0 })
  const [orderId, setOrderId] = useState<string | null>(null)
  const [status, setStatus] = useState('pending')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  const [rating, setRating] = useState(0)
  const [comment, setComment] = useState('')
  const [reviewed, setReviewed] = useState(false)

  useEffect(() => {
    supabase.from('food_items').select('*').eq('available', true).then(r => r.data && setFoods(r.data))
    supabase.from('food_categories').select('id,name').then(r => r.data && setCats(r.data))
    supabase.from('restaurant_settings').select('tax_percent,service_percent').single()
      .then(r => r.data && setTax({ tax: r.data.tax_percent, service: r.data.service_percent }))
  }, [])

  // real-time order status
  useEffect(() => {
    if (!orderId) return
    supabase.from('orders').select('status').eq('id', orderId).single().then(r => r.data && setStatus(r.data.status))
    const ch = supabase.channel('order-' + orderId)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'orders', filter: `id=eq.${orderId}` },
        p => setStatus((p.new as any).status))
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [orderId])

  const shown = useMemo(() => foods.filter(f =>
    (!cat || f.category_id === cat) && f.name.toLowerCase().includes(q.toLowerCase())), [foods, cat, q])
  const popular = useMemo(() => [...foods].sort((a, b) => b.orders_count - a.orders_count).slice(0, 3).filter(f => f.orders_count > 0), [foods])
  const lines = foods.filter(f => cart[f.id])
  const sub = lines.reduce((s, f) => s + f.price * cart[f.id], 0)
  const disc = lines.reduce((s, f) => s + f.price * cart[f.id] * f.discount_percent / 100, 0)
  const base = sub - disc
  const total = base * (1 + (tax.tax + tax.service) / 100) // preview only; server recalculates
  const change = (id: string, d: number) => setCart(c => {
    const n = (c[id] || 0) + d
    const { [id]: _, ...rest } = c
    return n > 0 ? { ...c, [id]: Math.min(n, 50) } : rest
  })

  async function place() {
    setErr(''); setBusy(true)
    const items = lines.map(f => ({ food_item_id: f.id, quantity: cart[f.id] }))
    const { data, error } = await supabase.rpc('place_order', { p_items: items, p_method: method })
    setBusy(false)
    if (error) return setErr(error.message)
    setCart({}); setOrderId(data)
  }

  async function review() {
    const { data: u } = await supabase.from('customers').select('id').single()
    const { error } = await supabase.from('reviews').insert({ order_id: orderId, customer_id: u!.id, rating, comment: comment.trim() || null })
    error ? setErr(error.message) : setReviewed(true)
  }

  if (!table) return <Navigate to="/" />

  if (orderId) {
    const at = STEPS.indexOf(status)
    return (
      <div className="mx-auto max-w-md space-y-4 p-6">
        <h1 className="text-xl font-bold">Table {table} · Order status</h1>
        {status === 'cancelled' ? <p className="font-semibold text-red-600">Order cancelled</p> : (
          <ol className="space-y-2">{STEPS.map((s, i) => (
            <li key={s} className={i <= at ? 'font-semibold text-brand' : 'opacity-40'}>{i <= at ? '✔' : '○'} {LABEL[s]}</li>))}
          </ol>)}
        {status === 'completed' && !reviewed && (
          <div className="space-y-2">
            <div>{[1, 2, 3, 4, 5].map(n => (
              <button key={n} aria-label={`${n} stars`} onClick={() => setRating(n)}
                className={`text-3xl ${n <= rating ? 'text-brand' : 'text-brown/30'}`}>★</button>))}</div>
            <textarea className="input" placeholder="Feedback (optional)" value={comment} onChange={e => setComment(e.target.value)} />
            <button className="btn" disabled={!rating} onClick={review}>Submit review</button>
          </div>)}
        {reviewed && <p>Thanks for your feedback!</p>}
        {err && <p role="alert" className="text-sm text-red-600">{err}</p>}
        {(status === 'completed' || status === 'cancelled') &&
          <button className="btn" onClick={() => { setOrderId(null); setReviewed(false) }}>Order again</button>}
      </div>)
  }

  const Card = ({ f }: { f: Food }) => (
    <div className="overflow-hidden rounded-xl bg-white shadow">
      {f.image_url && <img src={f.image_url} alt={f.name} className="h-32 w-full object-cover" loading="lazy" />}
      <div className="space-y-1 p-3">
        <p className="font-semibold">{f.is_veg ? '🟢' : '🔴'} {f.name}</p>
        {f.description && <p className="text-sm opacity-70">{f.description}</p>}
        <p>{money(f.price * (1 - f.discount_percent / 100))}
          {f.discount_percent > 0 && <span className="ml-2 text-sm text-brand">{f.discount_percent}% off</span>}</p>
        {cart[f.id] ? (
          <div className="flex items-center gap-3">
            <button className="btn px-3" onClick={() => change(f.id, -1)} aria-label="Decrease">−</button>
            <span>{cart[f.id]}</span>
            <button className="btn px-3" onClick={() => change(f.id, 1)} aria-label="Increase">+</button>
          </div>) : <button className="btn" onClick={() => change(f.id, 1)}>Add</button>}
      </div>
    </div>)

  return (
    <div className="mx-auto max-w-2xl space-y-4 p-4 pb-72">
      <header className="flex justify-between"><h1 className="text-xl font-bold text-brand">Menu</h1><span>Table {table}</span></header>
      <input className="input" placeholder="Search food" value={q} onChange={e => setQ(e.target.value)} />
      <div className="flex gap-2 overflow-x-auto">
        {[{ id: '', name: 'All' }, ...cats].map(c => (
          <button key={c.id} onClick={() => setCat(c.id)}
            className={`whitespace-nowrap rounded-full border px-3 py-1 ${cat === c.id ? 'bg-brand text-white' : 'bg-white'}`}>{c.name}</button>))}
      </div>
      {popular.length > 0 && !q && !cat && (<><h2 className="font-semibold">Popular</h2>
        <div className="grid grid-cols-2 gap-3">{popular.map(f => <Card key={f.id} f={f} />)}</div></>)}
      <div className="grid grid-cols-2 gap-3">{shown.map(f => <Card key={f.id} f={f} />)}</div>
      {shown.length === 0 && <p>No items found.</p>}

      {lines.length > 0 && (
        <div className="fixed inset-x-0 bottom-0 space-y-1 border-t bg-white p-4 shadow-lg">
          {lines.map(f => <div key={f.id} className="flex justify-between text-sm">
            <span>{f.name} × {cart[f.id]}</span><span>{money(f.price * cart[f.id])}</span></div>)}
          <div className="flex justify-between text-sm"><span>Subtotal</span><span>{money(sub)}</span></div>
          {disc > 0 && <div className="flex justify-between text-sm"><span>Discount</span><span>−{money(disc)}</span></div>}
          <div className="flex justify-between text-sm"><span>Tax + service</span><span>{money(total - base)}</span></div>
          <div className="flex justify-between font-bold"><span>Total</span><span>{money(total)}</span></div>
          <select className="input" value={method} onChange={e => setMethod(e.target.value as 'cash' | 'upi')}>
            <option value="cash">Cash</option><option value="upi">UPI</option></select>
          {err && <p role="alert" className="text-sm text-red-600">{err}</p>}
          <button className="btn w-full" disabled={busy} onClick={place}>{busy ? 'Placing…' : 'Place order'}</button>
        </div>)}
    </div>)
}
