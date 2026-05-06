'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@supabase/supabase-js'
import { Plus, Download, Trash2, LogOut } from 'lucide-react'

const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
)

export default function TradeJournal() {
  const [user, setUser] = useState(null)
  const [loading, setLoading] = useState(true)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [authMode, setAuthMode] = useState('login')
  const [authError, setAuthError] = useState('')
  const [trades, setTrades] = useState([])
  const [showForm, setShowForm] = useState(false)
  const [filterAsset, setFilterAsset] = useState('all')
  const [filterResult, setFilterResult] = useState('all')
  const [saving, setSaving] = useState(false)

  const [formData, setFormData] = useState({
    date: new Date().toISOString().split('T')[0],
    asset: 'Gold',
    entry_price: '',
    exit_price: '',
    stop_loss: '',
    result: 'win',
    pnl: '',
    rr_ratio: '',
    setup_type: 'FVG Fill',
    timeframe: '1H',
    emotional_state: 7,
    execution_grade: 'A',
    notes: '',
    screenshot_url: '',
  })

  useEffect(() => {
    const checkAuth = async () => {
      const { data: { session } } = await supabase.auth.getSession()
      setUser(session?.user || null)
      setLoading(false)
      
      if (session?.user) {
        fetchTrades(session.user.id)
      }
    }
    checkAuth()

    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, session) => {
      setUser(session?.user || null)
      if (session?.user) {
        fetchTrades(session.user.id)
      }
    })

    return () => subscription?.unsubscribe()
  }, [])

  const fetchTrades = async (userId) => {
    try {
      const { data, error } = await supabase
        .from('trades')
        .select('*')
        .eq('user_id', userId)
        .order('date', { ascending: false })
      
      if (error) throw error
      setTrades(data || [])
    } catch (err) {
      console.error('Error fetching trades:', err)
    }
  }

  const handleAuth = async (e) => {
    e.preventDefault()
    setAuthError('')
    setSaving(true)

    try {
      if (authMode === 'login') {
        const { error } = await supabase.auth.signInWithPassword({ email, password })
        if (error) throw error
      } else {
        const { error } = await supabase.auth.signUp({ email, password })
        if (error) throw error
        setAuthError('Check your email to confirm signup!')
      }
      setEmail('')
      setPassword('')
    } catch (err) {
      setAuthError(err.message || 'Auth error')
    } finally {
      setSaving(false)
    }
  }

  const handleLogout = async () => {
    await supabase.auth.signOut()
    setUser(null)
  }

  const handleInputChange = (e) => {
    const { name, value } = e.target
    setFormData(prev => ({ ...prev, [name]: value }))
  }

  const handleAddTrade = async (e) => {
    e.preventDefault()
    if (!formData.entry_price || !formData.exit_price || !user) {
      alert('Entry and Exit prices required')
      return
    }

    setSaving(true)
    try {
      const { error } = await supabase.from('trades').insert([{
        user_id: user.id,
        date: formData.date,
        asset: formData.asset,
        entry_price: parseFloat(formData.entry_price),
        exit_price: parseFloat(formData.exit_price),
        stop_loss: formData.stop_loss ? parseFloat(formData.stop_loss) : null,
        result: formData.result,
        pnl: parseFloat(formData.pnl || 0),
        rr_ratio: parseFloat(formData.rr_ratio || 0),
        setup_type: formData.setup_type,
        timeframe: formData.timeframe,
        emotional_state: parseInt(formData.emotional_state),
        execution_grade: formData.execution_grade,
        notes: formData.notes,
        screenshot_url: formData.screenshot_url,
      }])

      if (error) throw error

      setFormData({
        date: new Date().toISOString().split('T')[0],
        asset: 'Gold',
        entry_price: '',
        exit_price: '',
        stop_loss: '',
        result: 'win',
        pnl: '',
        rr_ratio: '',
        setup_type: 'FVG Fill',
        timeframe: '1H',
        emotional_state: 7,
        execution_grade: 'A',
        notes: '',
        screenshot_url: '',
      })
      setShowForm(false)
      fetchTrades(user.id)
    } catch (err) {
      alert('Error saving trade: ' + err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleDeleteTrade = async (tradeId) => {
    if (!confirm('Delete this trade?')) return
    
    try {
      const { error } = await supabase.from('trades').delete().eq('id', tradeId)
      if (error) throw error
      fetchTrades(user.id)
    } catch (err) {
      alert('Error deleting trade: ' + err.message)
    }
  }

  const handleExport = () => {
    const csv = [
      ['Date', 'Asset', 'Entry', 'Exit', 'Stop Loss', 'Result', 'P&L', 'R:R', 'Setup', 'TF', 'Emotion', 'Grade', 'Notes'].join(','),
      ...filteredTrades.map(t => [
        t.date, t.asset, t.entry_price, t.exit_price, t.stop_loss, t.result, t.pnl, t.rr_ratio, t.setup_type, t.timeframe, t.emotional_state, t.execution_grade, `"${t.notes || ''}"`
      ].join(','))
    ].join('\n')
    
    const blob = new Blob([csv], { type: 'text/csv' })
    const url = window.URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `trade-journal-${new Date().toISOString().split('T')[0]}.csv`
    a.click()
  }

  const filteredTrades = trades.filter(t => {
    if (filterAsset !== 'all' && t.asset !== filterAsset) return false
    if (filterResult !== 'all' && t.result !== filterResult) return false
    return true
  })

  const stats = {
    totalTrades: filteredTrades.length,
    wins: filteredTrades.filter(t => t.result === 'win').length,
    losses: filteredTrades.filter(t => t.result === 'loss').length,
    breakeven: filteredTrades.filter(t => t.result === 'breakeven').length,
    winRate: filteredTrades.length > 0 ? Math.round((filteredTrades.filter(t => t.result === 'win').length / filteredTrades.length) * 100) : 0,
    totalPnL: filteredTrades.reduce((sum, t) => sum + (t.pnl || 0), 0),
    avgRR: filteredTrades.length > 0 ? (filteredTrades.reduce((sum, t) => sum + (t.rr_ratio || 0), 0) / filteredTrades.length).toFixed(2) : 0,
  }

  const assets = ['Gold', 'SPX500', 'DAX40', 'FTSE100', 'NDX100']
  const setupTypes = ['FVG Fill', 'Order Block', 'Liquidity Grab', 'Structure Break', 'Reversal', 'Range Break']
  const timeframes = ['15M', '30M', '1H', '4H', 'Daily']

  if (loading) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950 flex items-center justify-center">
        <div className="text-center">
          <div className="text-4xl font-bold text-transparent bg-clip-text bg-gradient-to-r from-amber-400 to-amber-300 mb-2">
            EXECUTION DESK
          </div>
          <p className="text-slate-400 text-sm">Loading...</p>
        </div>
      </div>
    )
  }

  if (!user) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950 flex items-center justify-center p-4">
        <div className="w-full max-w-md">
          <div className="text-center mb-8">
            <h1 className="text-4xl font-bold text-transparent bg-clip-text bg-gradient-to-r from-amber-400 to-amber-300 mb-2">
              EXECUTION DESK
            </h1>
            <p className="text-slate-400 text-sm tracking-widest">PRIVATE TRADE JOURNAL</p>
          </div>
          <form onSubmit={handleAuth} className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-8">
            <div className="mb-4">
              <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">EMAIL</label>
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
                className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-4 py-3 text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500/50 focus:ring-1 focus:ring-amber-500/30 transition"
              />
            </div>
            <div className="mb-6">
              <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">PASSWORD</label>
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="••••••••"
                className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-4 py-3 text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500/50 focus:ring-1 focus:ring-amber-500/30 transition"
              />
            </div>
            {authError && <div className="mb-4 p-3 bg-red-500/20 border border-red-500/50 rounded text-red-300 text-sm">{authError}</div>}
            <button
              type="submit"
              disabled={saving}
              className="w-full bg-gradient-to-r from-amber-500 to-amber-400 text-slate-950 font-semibold py-3 rounded transition hover:shadow-lg hover:shadow-amber-500/20 disabled:opacity-50"
            >
              {saving ? 'Processing...' : authMode === 'login' ? 'LOGIN' : 'CREATE ACCOUNT'}
            </button>
            <div className="mt-4 text-center">
              <button
                type="button"
                onClick={() => setAuthMode(authMode === 'login' ? 'signup' : 'login')}
                className="text-amber-400 hover:text-amber-300 text-sm transition"
              >
                {authMode === 'login' ? 'Need an account?' : 'Already have an account?'}
              </button>
            </div>
          </form>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950 text-slate-100 p-4 md:p-8">
      <div className="mb-8">
        <div className="flex items-center justify-between mb-2">
          <h1 className="text-4xl md:text-5xl font-bold text-transparent bg-clip-text bg-gradient-to-r from-amber-400 to-amber-300">
            EXECUTION DESK
          </h1>
          <div className="flex items-center gap-4">
            <span className="text-slate-400 text-sm">{user.email}</span>
            <button
              onClick={handleLogout}
              className="text-slate-400 hover:text-slate-200 text-sm transition flex items-center gap-1"
            >
              <LogOut size={16} /> Logout
            </button>
          </div>
        </div>
        <p className="text-slate-400 text-sm tracking-widest">PRIVATE TRADE JOURNAL — Cloud Synced | Real-time Analytics</p>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-6 gap-3 mb-8">
        <div className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-4">
          <p className="text-slate-400 text-xs tracking-widest mb-2">TOTAL TRADES</p>
          <p className="text-2xl font-bold text-slate-100">{stats.totalTrades}</p>
        </div>
        <div className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-4">
          <p className="text-slate-400 text-xs tracking-widest mb-2">WINS</p>
          <p className="text-2xl font-bold text-emerald-400">{stats.wins}</p>
        </div>
        <div className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-4">
          <p className="text-slate-400 text-xs tracking-widest mb-2">LOSSES</p>
          <p className="text-2xl font-bold text-red-400">{stats.losses}</p>
        </div>
        <div className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-4">
          <p className="text-slate-400 text-xs tracking-widest mb-2">WIN RATE</p>
          <p className="text-2xl font-bold text-amber-400">{stats.winRate}%</p>
        </div>
        <div className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-4">
          <p className="text-slate-400 text-xs tracking-widest mb-2">TOTAL P&L</p>
          <p className={`text-2xl font-bold ${stats.totalPnL >= 0 ? 'text-emerald-400' : 'text-red-400'}`}>
            ${stats.totalPnL.toFixed(2)}
          </p>
        </div>
        <div className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-4">
          <p className="text-slate-400 text-xs tracking-widest mb-2">AVG R:R</p>
          <p className="text-2xl font-bold text-slate-100">{stats.avgRR}</p>
        </div>
      </div>

      <div className="flex gap-3 mb-8 flex-wrap">
        <button
          onClick={() => setShowForm(!showForm)}
          className="flex items-center gap-2 bg-gradient-to-r from-amber-500 to-amber-400 text-slate-950 px-6 py-3 rounded font-semibold hover:shadow-lg hover:shadow-amber-500/20 transition"
        >
          <Plus size={18} /> NEW TRADE
        </button>
        <button
          onClick={handleExport}
          className="flex items-center gap-2 bg-slate-700/40 hover:bg-slate-700/60 text-slate-200 px-6 py-3 rounded font-semibold transition border border-slate-600/50"
        >
          <Download size={18} /> EXPORT CSV
        </button>
        <select
          value={filterAsset}
          onChange={(e) => setFilterAsset(e.target.value)}
          className="bg-slate-700/40 hover:bg-slate-700/60 text-slate-200 px-4 py-3 rounded font-semibold transition border border-slate-600/50"
        >
          <option value="all">All Assets</option>
          {assets.map(a => <option key={a} value={a}>{a}</option>)}
        </select>
        <select
          value={filterResult}
          onChange={(e) => setFilterResult(e.target.value)}
          className="bg-slate-700/40 hover:bg-slate-700/60 text-slate-200 px-4 py-3 rounded font-semibold transition border border-slate-600/50"
        >
          <option value="all">All Results</option>
          <option value="win">Wins Only</option>
          <option value="loss">Losses Only</option>
          <option value="breakeven">Breakeven Only</option>
        </select>
      </div>

      {showForm && (
        <div className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-8 mb-8">
          <h2 className="text-2xl font-bold mb-6 text-amber-400">LOG NEW TRADE</h2>
          <form onSubmit={handleAddTrade} className="space-y-6">
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">DATE</label>
                <input type="date" name="date" value={formData.date} onChange={handleInputChange} className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50" />
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">ASSET</label>
                <select name="asset" value={formData.asset} onChange={handleInputChange} className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50">
                  {assets.map(a => <option key={a} value={a}>{a}</option>)}
                </select>
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">ENTRY</label>
                <input type="number" step="0.01" name="entry_price" value={formData.entry_price} onChange={handleInputChange} placeholder="1234.50" className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50" />
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">EXIT</label>
                <input type="number" step="0.01" name="exit_price" value={formData.exit_price} onChange={handleInputChange} placeholder="1235.50" className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50" />
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">STOP LOSS</label>
                <input type="number" step="0.01" name="stop_loss" value={formData.stop_loss} onChange={handleInputChange} placeholder="1233.50" className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50" />
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">P&L ($)</label>
                <input type="number" step="0.01" name="pnl" value={formData.pnl} onChange={handleInputChange} placeholder="50.00" className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50" />
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">R:R RATIO</label>
                <input type="number" step="0.1" name="rr_ratio" value={formData.rr_ratio} onChange={handleInputChange} placeholder="2.5" className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50" />
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">RESULT</label>
                <select name="result" value={formData.result} onChange={handleInputChange} className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50">
                  <option value="win">Win</option>
                  <option value="loss">Loss</option>
                  <option value="breakeven">Breakeven</option>
                </select>
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">SETUP TYPE</label>
                <select name="setup_type" value={formData.setup_type} onChange={handleInputChange} className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50">
                  {setupTypes.map(s => <option key={s} value={s}>{s}</option>)}
                </select>
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">TIMEFRAME</label>
                <select name="timeframe" value={formData.timeframe} onChange={handleInputChange} className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50">
                  {timeframes.map(t => <option key={t} value={t}>{t}</option>)}
                </select>
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">EMOTION (1-10)</label>
                <input type="number" min="1" max="10" name="emotional_state" value={formData.emotional_state} onChange={handleInputChange} className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50" />
              </div>
              <div>
                <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">GRADE</label>
                <select name="execution_grade" value={formData.execution_grade} onChange={handleInputChange} className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50">
                  <option value="A">A</option>
                  <option value="B">B</option>
                  <option value="C">C</option>
                  <option value="F">F</option>
                </select>
              </div>
            </div>
            <div>
              <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">NOTES</label>
              <textarea name="notes" value={formData.notes} onChange={handleInputChange} placeholder="Trade analysis, what went right/wrong, lessons learned..." rows="4" className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50 resize-none"></textarea>
            </div>
            <div>
              <label className="block text-slate-300 text-xs tracking-widest mb-2 font-medium">SCREENSHOT URL (optional)</label>
              <input type="url" name="screenshot_url" value={formData.screenshot_url} onChange={handleInputChange} placeholder="https://..." className="w-full bg-slate-900/50 border border-slate-600/50 rounded px-3 py-2 text-slate-100 text-sm focus:outline-none focus:border-amber-500/50" />
            </div>
            <div className="flex gap-3">
              <button type="submit" disabled={saving} className="flex-1 bg-gradient-to-r from-amber-500 to-amber-400 text-slate-950 py-3 rounded font-semibold hover:shadow-lg hover:shadow-amber-500/20 transition disabled:opacity-50">
                {saving ? 'SAVING...' : 'LOG TRADE'}
              </button>
              <button type="button" onClick={() => setShowForm(false)} className="flex-1 bg-slate-700/40 text-slate-200 py-3 rounded font-semibold border border-slate-600/50 hover:bg-slate-700/60 transition">
                CANCEL
              </button>
            </div>
          </form>
        </div>
      )}

      <div className="space-y-4">
        <h2 className="text-xl font-bold text-slate-100 tracking-wide">TRADE HISTORY</h2>
        {filteredTrades.length === 0 ? (
          <div className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-8 text-center">
            <p className="text-slate-400 text-sm">No trades logged yet. Click "NEW TRADE" to start.</p>
          </div>
        ) : (
          <div className="space-y-3">
            {filteredTrades.map(trade => (
              <div key={trade.id} className="bg-slate-800/40 backdrop-blur border border-slate-700/50 rounded-lg p-5 hover:border-slate-600/70 transition">
                <div className="grid grid-cols-2 md:grid-cols-7 gap-4 mb-4">
                  <div>
                    <p className="text-slate-400 text-xs tracking-widest mb-1">DATE</p>
                    <p className="font-semibold text-slate-100">{trade.date}</p>
                  </div>
                  <div>
                    <p className="text-slate-400 text-xs tracking-widest mb-1">ASSET</p>
                    <p className="font-semibold text-slate-100">{trade.asset}</p>
                  </div>
                  <div>
                    <p className="text-slate-400 text-xs tracking-widest mb-1">ENTRY → EXIT</p>
                    <p className="font-semibold text-slate-100">{trade.entry_price} → {trade.exit_price}</p>
                  </div>
                  <div>
                    <p className="text-slate-400 text-xs tracking-widest mb-1">P&L</p>
                    <p className={`font-semibold text-lg ${trade.pnl >= 0 ? 'text-emerald-400' : 'text-red-400'}`}>
                      ${trade.pnl.toFixed(2)}
                    </p>
                  </div>
                  <div>
                    <p className="text-slate-400 text-xs tracking-widest mb-1">R:R</p>
                    <p className="font-semibold text-slate-100">{trade.rr_ratio}</p>
                  </div>
                  <div>
                    <p className="text-slate-400 text-xs tracking-widest mb-1">GRADE</p>
                    <p className={`font-semibold text-lg ${trade.execution_grade === 'A' ? 'text-emerald-400' : trade.execution_grade === 'B' ? 'text-amber-400' : 'text-slate-300'}`}>
                      {trade.execution_grade}
                    </p>
                  </div>
                  <div>
                    <p className="text-slate-400 text-xs tracking-widest mb-1">EMOTION</p>
                    <p className="font-semibold text-slate-100">{trade.emotional_state}/10</p>
                  </div>
                </div>
                {trade.notes && (
                  <div className="bg-slate-900/30 rounded p-3 mb-4 border-l-2 border-amber-500/50">
                    <p className="text-slate-300 text-sm">{trade.notes}</p>
                  </div>
                )}
                {trade.screenshot_url && (
                  <div className="mb-4">
                    <img src={trade.screenshot_url} alt="Trade screenshot" className="max-w-full h-auto rounded border border-slate-600/50" />
                  </div>
                )}
                <div className="flex gap-2 justify-end">
                  <button
                    onClick={() => handleDeleteTrade(trade.id)}
                    className="flex items-center gap-1 text-red-400 hover:text-red-300 text-xs font-medium transition"
                  >
                    <Trash2 size={16} /> DELETE
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="mt-12 pt-8 border-t border-slate-700/30 text-center text-slate-500 text-xs tracking-widest">
        <p>EXECUTION DESK — PRIVATE TRADE JOURNAL | Cloud Synced with Supabase</p>
      </div>
    </div>
  )
}
