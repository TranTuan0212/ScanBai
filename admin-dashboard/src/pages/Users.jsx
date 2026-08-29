import React, { useState, useEffect } from 'react';
import api from '../api/client';
import UserTable from '../components/UserTable';
import { UserPlus, RefreshCw, X, AlertCircle } from 'lucide-react';

export default function Users() {
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  
  // Create User Modal state
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [createForm, setCreateForm] = useState({
    email: '',
    password: '',
    role: 'live',
    duration: 30,
    durationUnit: 'day'
  });

  // Renew Modal state
  const [renewUser, setRenewUser] = useState(null);
  const [renewForm, setRenewForm] = useState({
    duration: 30,
    durationUnit: 'day'
  });

  const fetchUsers = async () => {
    try {
      setLoading(true);
      setError('');
      const res = await api.get('/admin/users');
      setUsers(res.data);
    } catch (err) {
      setError(err.response?.data?.error || 'Không thể tải danh sách người dùng');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchUsers();
  }, []);

  const handleCreateUser = async (e) => {
    e.preventDefault();
    try {
      setError('');
      await api.post('/admin/users', createForm);
      setShowCreateModal(false);
      setCreateForm({
        email: '',
        password: '',
        role: 'live',
        duration: 30,
        durationUnit: 'day'
      });
      fetchUsers();
    } catch (err) {
      setError(err.response?.data?.error || 'Tạo người dùng thất bại');
    }
  };

  const handleRenewUser = async (e) => {
    e.preventDefault();
    if (!renewUser) return;
    try {
      setError('');
      await api.put(`/admin/users/${renewUser.id}/renew`, renewForm);
      setRenewUser(null);
      fetchUsers();
    } catch (err) {
      setError(err.response?.data?.error || 'Gia hạn thất bại');
    }
  };

  const handleDeleteUser = async (user) => {
    if (!window.confirm(`Bạn có chắc chắn muốn xóa tài khoản ${user.email}?`)) {
      return;
    }
    try {
      setError('');
      await api.delete(`/admin/users/${user.id}`);
      fetchUsers();
    } catch (err) {
      if (err.response?.status === 409) {
        setError('Không thể xóa tài khoản này vì đang có phiên Live phát trực tiếp!');
      } else {
        setError(err.response?.data?.error || 'Xóa tài khoản thất bại');
      }
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white tracking-tight">Quản Lý Người Dùng</h1>
          <p className="text-sm text-slate-400">Tạo mới, phân quyền và gia hạn thời hạn sử dụng</p>
        </div>
        <button
          onClick={() => setShowCreateModal(true)}
          className="flex items-center space-x-2 px-4 py-2.5 bg-red-600 hover:bg-red-700 text-white font-medium rounded-xl shadow-lg shadow-red-900/30 transition"
        >
          <UserPlus className="w-4 h-4" />
          <span>Tạo Tài Khoản Mới</span>
        </button>
      </div>

      {error && (
        <div className="p-4 bg-rose-500/10 border border-rose-500/30 rounded-xl flex items-center space-x-3 text-rose-400 text-sm">
          <AlertCircle className="w-5 h-5 flex-shrink-0" />
          <span>{error}</span>
        </div>
      )}

      {loading ? (
        <div className="py-12 flex justify-center items-center">
          <div className="w-8 h-8 border-4 border-red-500 border-t-transparent rounded-full animate-spin"></div>
        </div>
      ) : (
        <UserTable
          users={users}
          onRenew={(u) => setRenewUser(u)}
          onDelete={handleDeleteUser}
        />
      )}

      {/* Modal Tạo User Mới */}
      {showCreateModal && (
        <div className="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center p-4 z-50">
          <div className="bg-slate-850 bg-slate-900 border border-slate-700 rounded-2xl max-w-md w-full p-6 shadow-2xl">
            <div className="flex items-center justify-between pb-4 border-b border-slate-800">
              <h2 className="text-lg font-bold text-white">Tạo Tài Khoản Mới</h2>
              <button
                onClick={() => setShowCreateModal(false)}
                className="text-slate-400 hover:text-white"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            <form onSubmit={handleCreateUser} className="space-y-4 mt-4">
              <div>
                <label className="block text-xs font-semibold text-slate-400 uppercase mb-1">Email</label>
                <input
                  type="email"
                  required
                  value={createForm.email}
                  onChange={(e) => setCreateForm({ ...createForm, email: e.target.value })}
                  className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3.5 py-2 text-white focus:outline-none focus:ring-2 focus:ring-red-500/50 text-sm"
                  placeholder="user@cardlink.com"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-400 uppercase mb-1">Mật khẩu</label>
                <input
                  type="password"
                  required
                  value={createForm.password}
                  onChange={(e) => setCreateForm({ ...createForm, password: e.target.value })}
                  className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3.5 py-2 text-white focus:outline-none focus:ring-2 focus:ring-red-500/50 text-sm"
                  placeholder="••••••••"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-400 uppercase mb-1">Quyền Hạn (Role)</label>
                <select
                  value={createForm.role}
                  onChange={(e) => setCreateForm({ ...createForm, role: e.target.value })}
                  className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3.5 py-2 text-white focus:outline-none focus:ring-2 focus:ring-red-500/50 text-sm"
                >
                  <option value="live">Live (Broadcaster + Viewer)</option>
                  <option value="view">View (Chỉ xem)</option>
                  <option value="admin">Admin (Quản trị)</option>
                </select>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-semibold text-slate-400 uppercase mb-1">Thời hạn</label>
                  <input
                    type="number"
                    min="1"
                    required
                    value={createForm.duration}
                    onChange={(e) => setCreateForm({ ...createForm, duration: e.target.value })}
                    className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3.5 py-2 text-white focus:outline-none focus:ring-2 focus:ring-red-500/50 text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs font-semibold text-slate-400 uppercase mb-1">Đơn vị</label>
                  <select
                    value={createForm.durationUnit}
                    onChange={(e) => setCreateForm({ ...createForm, durationUnit: e.target.value })}
                    className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3.5 py-2 text-white focus:outline-none focus:ring-2 focus:ring-red-500/50 text-sm"
                  >
                    <option value="day">Ngày (Day)</option>
                    <option value="month">Tháng (Month)</option>
                    <option value="year">Năm (Year)</option>
                  </select>
                </div>
              </div>

              <div className="flex space-x-3 pt-3">
                <button
                  type="button"
                  onClick={() => setShowCreateModal(false)}
                  className="w-1/2 py-2.5 bg-slate-800 hover:bg-slate-700 text-slate-300 rounded-xl text-sm font-medium transition"
                >
                  Hủy
                </button>
                <button
                  type="submit"
                  className="w-1/2 py-2.5 bg-red-600 hover:bg-red-700 text-white rounded-xl text-sm font-medium transition shadow-lg shadow-red-900/30"
                >
                  Tạo Mới
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Modal Gia Hạn Tài Khoản */}
      {renewUser && (
        <div className="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center p-4 z-50">
          <div className="bg-slate-850 bg-slate-900 border border-slate-700 rounded-2xl max-w-md w-full p-6 shadow-2xl">
            <div className="flex items-center justify-between pb-4 border-b border-slate-800">
              <div>
                <h2 className="text-lg font-bold text-white">Gia Hạn Tài Khoản</h2>
                <p className="text-xs text-slate-400 mt-0.5">{renewUser.email}</p>
              </div>
              <button
                onClick={() => setRenewUser(null)}
                className="text-slate-400 hover:text-white"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            <form onSubmit={handleRenewUser} className="space-y-4 mt-4">
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-semibold text-slate-400 uppercase mb-1">Cộng thêm</label>
                  <input
                    type="number"
                    min="1"
                    required
                    value={renewForm.duration}
                    onChange={(e) => setRenewForm({ ...renewForm, duration: e.target.value })}
                    className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3.5 py-2 text-white focus:outline-none focus:ring-2 focus:ring-red-500/50 text-sm"
                  />
                </div>
                <div>
                  <label className="block text-xs font-semibold text-slate-400 uppercase mb-1">Đơn vị</label>
                  <select
                    value={renewForm.durationUnit}
                    onChange={(e) => setRenewForm({ ...renewForm, durationUnit: e.target.value })}
                    className="w-full bg-slate-800 border border-slate-700 rounded-xl px-3.5 py-2 text-white focus:outline-none focus:ring-2 focus:ring-red-500/50 text-sm"
                  >
                    <option value="day">Ngày (Day)</option>
                    <option value="month">Tháng (Month)</option>
                    <option value="year">Năm (Year)</option>
                  </select>
                </div>
              </div>

              <div className="flex space-x-3 pt-3">
                <button
                  type="button"
                  onClick={() => setRenewUser(null)}
                  className="w-1/2 py-2.5 bg-slate-800 hover:bg-slate-700 text-slate-300 rounded-xl text-sm font-medium transition"
                >
                  Hủy
                </button>
                <button
                  type="submit"
                  className="w-1/2 py-2.5 bg-indigo-600 hover:bg-indigo-700 text-white rounded-xl text-sm font-medium transition shadow-lg shadow-indigo-900/30"
                >
                  Xác Nhận Gia Hạn
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
