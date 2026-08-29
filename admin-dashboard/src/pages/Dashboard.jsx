import React, { useState, useEffect } from 'react';
import api from '../api/client';
import { Users, Radio, Activity, RefreshCw } from 'lucide-react';

export default function Dashboard() {
  const [stats, setStats] = useState({ totalUsers: 0, activeLives: 0 });
  const [loading, setLoading] = useState(true);

  const fetchStats = async () => {
    try {
      setLoading(true);
      const res = await api.get('/admin/dashboard');
      setStats(res.data);
    } catch (err) {
      console.error('Failed to fetch dashboard stats', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchStats();
    const interval = setInterval(fetchStats, 10000);
    return () => clearInterval(interval);
  }, []);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white tracking-tight">Tổng Quan Hệ Thống</h1>
          <p className="text-sm text-slate-400">Trạng thái phát trực tiếp và tài khoản trong mạng Wi-Fi</p>
        </div>
        <button
          onClick={fetchStats}
          disabled={loading}
          className="flex items-center space-x-1 px-3.5 py-2 bg-slate-800 hover:bg-slate-700 text-slate-200 rounded-lg text-sm border border-slate-700 transition"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          <span>Làm mới</span>
        </button>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="bg-slate-800 border border-slate-700 p-6 rounded-2xl shadow-md flex items-center space-x-4">
          <div className="p-4 bg-indigo-500/10 border border-indigo-500/20 rounded-2xl text-indigo-400">
            <Users className="w-8 h-8" />
          </div>
          <div>
            <p className="text-sm font-medium text-slate-400 uppercase tracking-wider">Tổng Số Người Dùng</p>
            <h2 className="text-3xl font-extrabold text-white mt-1">{stats.totalUsers}</h2>
          </div>
        </div>

        <div className="bg-slate-800 border border-slate-700 p-6 rounded-2xl shadow-md flex items-center space-x-4">
          <div className="p-4 bg-red-500/10 border border-red-500/20 rounded-2xl text-red-500">
            <Radio className="w-8 h-8 animate-pulse" />
          </div>
          <div>
            <p className="text-sm font-medium text-slate-400 uppercase tracking-wider">Phiên Live Đang Phát</p>
            <h2 className="text-3xl font-extrabold text-white mt-1">{stats.activeLives}</h2>
          </div>
        </div>
      </div>

      <div className="bg-slate-800/60 border border-slate-700/80 rounded-2xl p-6">
        <div className="flex items-center space-x-2 text-white font-semibold mb-3">
          <Activity className="w-5 h-5 text-emerald-400" />
          <span>Ghi Chú Vận Hành Hệ Thống</span>
        </div>
        <ul className="text-sm text-slate-300 space-y-2 list-disc list-inside">
          <li>Thiết bị Android Live và Android Viewer cần kết nối chung một điểm phát Wi-Fi với máy tính chạy Server.</li>
          <li>Khi tài khoản hết hạn, phiên Live sẽ tự động bị ngắt và giải phóng Redis Live Lock.</li>
          <li>Thao tác xóa tài khoản đang phát sóng trực tiếp sẽ bị từ chối với mã lỗi 409 để đảm bảo tính toàn vẹn dữ liệu.</li>
        </ul>
      </div>
    </div>
  );
}
