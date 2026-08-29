import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import api, { getBaseUrl } from '../api/client';
import { Radio, Lock, Mail, Server, AlertCircle } from 'lucide-react';

export default function Login() {
  const navigate = useNavigate();
  const [email, setEmail] = useState('admin@cardlink.com');
  const [password, setPassword] = useState('admin123');
  const [serverUrl, setServerUrl] = useState(
    localStorage.getItem('server_api_url') || `http://${window.location.hostname || 'localhost'}:3000/api`
  );
  const [showConfig, setShowConfig] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      localStorage.setItem('server_api_url', serverUrl);
      const res = await api.post('/auth/login', {
        email,
        password,
        deviceId: 'admin-web-client'
      });

      if (res.data.user.role !== 'admin') {
        setError('Tài khoản không có quyền Admin');
        setLoading(false);
        return;
      }

      localStorage.setItem('admin_token', res.data.token);
      localStorage.setItem('admin_user', JSON.stringify(res.data.user));
      navigate('/');
    } catch (err) {
      setError(
        err.response?.data?.error || 'Đăng nhập thất bại. Vui lòng kiểm tra kết nối Server.'
      );
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center p-4 bg-gradient-to-br from-slate-950 via-slate-900 to-slate-800">
      <div className="max-w-md w-full bg-slate-850 bg-slate-900/90 backdrop-blur border border-slate-700/80 rounded-2xl p-8 shadow-2xl">
        <div className="text-center mb-8">
          <div className="inline-flex p-3 bg-red-500/10 rounded-2xl border border-red-500/20 mb-3">
            <Radio className="w-8 h-8 text-red-500 animate-pulse" />
          </div>
          <h1 className="text-2xl font-bold text-white tracking-tight">CardLink Admin</h1>
          <p className="text-sm text-slate-400 mt-1">Đăng nhập trang quản trị máy chủ phát sóng</p>
        </div>

        {error && (
          <div className="mb-6 p-3.5 bg-rose-500/10 border border-rose-500/30 rounded-xl flex items-center space-x-2 text-rose-400 text-sm">
            <AlertCircle className="w-5 h-5 flex-shrink-0" />
            <span>{error}</span>
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-1.5">
              Email Quản Trị
            </label>
            <div className="relative">
              <Mail className="w-5 h-5 text-slate-500 absolute left-3.5 top-3" />
              <input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-full bg-slate-800 border border-slate-700 rounded-xl pl-11 pr-4 py-2.5 text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-red-500/50"
                placeholder="admin@cardlink.com"
              />
            </div>
          </div>

          <div>
            <label className="block text-xs font-semibold text-slate-300 uppercase tracking-wider mb-1.5">
              Mật Khẩu
            </label>
            <div className="relative">
              <Lock className="w-5 h-5 text-slate-500 absolute left-3.5 top-3" />
              <input
                type="password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full bg-slate-800 border border-slate-700 rounded-xl pl-11 pr-4 py-2.5 text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-red-500/50"
                placeholder="••••••••"
              />
            </div>
          </div>

          <div className="pt-1">
            <button
              type="button"
              onClick={() => setShowConfig(!showConfig)}
              className="text-xs text-indigo-400 hover:text-indigo-300 flex items-center space-x-1"
            >
              <Server className="w-3.5 h-3.5" />
              <span>{showConfig ? 'Ẩn cấu hình Server IP Wi-Fi' : 'Tùy chỉnh Server IP Wi-Fi'}</span>
            </button>

            {showConfig && (
              <div className="mt-2 p-3 bg-slate-950/70 border border-slate-800 rounded-lg">
                <label className="block text-xs text-slate-400 mb-1">Địa chỉ API Server</label>
                <input
                  type="text"
                  value={serverUrl}
                  onChange={(e) => setServerUrl(e.target.value)}
                  className="w-full bg-slate-800 border border-slate-700 rounded px-2.5 py-1.5 text-xs text-slate-200 font-mono focus:outline-none"
                  placeholder="http://192.168.1.100:3000/api"
                />
              </div>
            )}
          </div>

          <button
            type="submit"
            disabled={loading}
            className="w-full mt-6 py-3 bg-red-600 hover:bg-red-700 disabled:opacity-50 text-white rounded-xl font-semibold transition duration-200 shadow-lg shadow-red-900/30 flex items-center justify-center space-x-2"
          >
            {loading ? (
              <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
            ) : (
              <span>Đăng Nhập</span>
            )}
          </button>
        </form>
      </div>
    </div>
  );
}
