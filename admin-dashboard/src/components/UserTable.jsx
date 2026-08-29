import React from 'react';
import { Calendar, Trash2, RefreshCw, Shield, Tv, Eye } from 'lucide-react';

export default function UserTable({ users, onRenew, onDelete }) {
  const isExpired = (expiredAt) => new Date(expiredAt) <= new Date();

  return (
    <div className="overflow-x-auto bg-slate-800 rounded-xl border border-slate-700 shadow-lg">
      <table className="w-full text-left text-sm text-slate-300">
        <thead className="bg-slate-900/60 text-xs uppercase tracking-wider text-slate-400 border-b border-slate-700">
          <tr>
            <th className="px-6 py-4">Email</th>
            <th className="px-6 py-4">Quyền (Role)</th>
            <th className="px-6 py-4">Hạn Sử Dụng</th>
            <th className="px-6 py-4">Trạng Thái</th>
            <th className="px-6 py-4 text-right">Thao Tác</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-700/50">
          {users.map((user) => {
            const expired = isExpired(user.expiredAt);
            return (
              <tr key={user.id} className="hover:bg-slate-750/50 transition">
                <td className="px-6 py-4 font-medium text-white">{user.email}</td>
                <td className="px-6 py-4">
                  <span
                    className={`inline-flex items-center space-x-1 px-2.5 py-0.5 rounded-full text-xs font-semibold ${
                      user.role === 'admin'
                        ? 'bg-purple-900/50 text-purple-300 border border-purple-700'
                        : user.role === 'live'
                        ? 'bg-red-900/50 text-red-300 border border-red-700'
                        : 'bg-blue-900/50 text-blue-300 border border-blue-700'
                    }`}
                  >
                    {user.role === 'admin' ? (
                      <Shield className="w-3 h-3" />
                    ) : user.role === 'live' ? (
                      <Tv className="w-3 h-3" />
                    ) : (
                      <Eye className="w-3 h-3" />
                    )}
                    <span>{user.role.toUpperCase()}</span>
                  </span>
                </td>
                <td className="px-6 py-4 font-mono text-xs">
                  {new Date(user.expiredAt).toLocaleString('vi-VN')}
                </td>
                <td className="px-6 py-4">
                  <span
                    className={`px-2.5 py-1 rounded-md text-xs font-medium ${
                      expired
                        ? 'bg-red-500/20 text-red-400 border border-red-500/30'
                        : 'bg-emerald-500/20 text-emerald-400 border border-emerald-500/30'
                    }`}
                  >
                    {expired ? 'Hết hạn' : 'Đang hoạt động'}
                  </span>
                </td>
                <td className="px-6 py-4 text-right space-x-2">
                  <button
                    onClick={() => onRenew(user)}
                    title="Gia hạn thời gian"
                    className="inline-flex items-center space-x-1 px-2.5 py-1.5 bg-indigo-600 hover:bg-indigo-700 text-white rounded text-xs font-medium transition"
                  >
                    <RefreshCw className="w-3.5 h-3.5" />
                    <span>Gia hạn</span>
                  </button>
                  <button
                    onClick={() => onDelete(user)}
                    title="Xóa tài khoản"
                    className="inline-flex items-center space-x-1 px-2.5 py-1.5 bg-rose-600/80 hover:bg-rose-700 text-white rounded text-xs font-medium transition"
                  >
                    <Trash2 className="w-3.5 h-3.5" />
                    <span>Xóa</span>
                  </button>
                </td>
              </tr>
            );
          })}
          {users.length === 0 && (
            <tr>
              <td colSpan="5" className="px-6 py-8 text-center text-slate-500">
                Chưa có tài khoản nào.
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
