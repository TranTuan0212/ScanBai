import React from 'react';
import { Link, useNavigate, useLocation } from 'react-router-dom';
import { LayoutDashboard, Users, LogOut, Radio, Tv } from 'lucide-react';

export default function Navbar() {
  const navigate = useNavigate();
  const location = useLocation();
  const userStr = localStorage.getItem('admin_user');
  const user = userStr ? JSON.parse(userStr) : null;

  const handleLogout = () => {
    localStorage.removeItem('admin_token');
    localStorage.removeItem('admin_user');
    navigate('/login');
  };

  return (
    <nav className="bg-slate-800 border-b border-slate-700 px-6 py-4 flex items-center justify-between shadow-md">
      <div className="flex items-center space-x-8">
        <div className="flex items-center space-x-2">
          <Radio className="w-6 h-6 text-red-500 animate-pulse" />
          <span className="text-xl font-bold tracking-wide text-white">CardLink Admin</span>
        </div>
        <div className="flex space-x-4">
          <Link
            to="/"
            className={`flex items-center space-x-1 px-3 py-2 rounded-md text-sm font-medium transition ${
              location.pathname === '/' ? 'bg-slate-900 text-white' : 'text-slate-300 hover:bg-slate-700'
            }`}
          >
            <LayoutDashboard className="w-4 h-4" />
            <span>Dashboard</span>
          </Link>
          <Link
            to="/viewer"
            className={`flex items-center space-x-1 px-3 py-2 rounded-md text-sm font-medium transition ${
              location.pathname === '/viewer'
                ? 'bg-red-600/90 text-white font-bold'
                : 'text-slate-300 hover:bg-slate-700'
            }`}
          >
            <Tv className="w-4 h-4 text-red-400" />
            <span>Xem Live (Viewer)</span>
          </Link>
          <Link
            to="/users"
            className={`flex items-center space-x-1 px-3 py-2 rounded-md text-sm font-medium transition ${
              location.pathname === '/users' ? 'bg-slate-900 text-white' : 'text-slate-300 hover:bg-slate-700'
            }`}
          >
            <Users className="w-4 h-4" />
            <span>Quản lý Tài khoản</span>
          </Link>
        </div>
      </div>

      <div className="flex items-center space-x-4">
        {user && (
          <span className="text-xs bg-slate-700 text-slate-300 px-3 py-1.5 rounded-full border border-slate-600">
            {user.email} ({user.role})
          </span>
        )}
        <button
          onClick={handleLogout}
          className="flex items-center space-x-1 px-3 py-1.5 rounded-md text-sm font-medium bg-red-600 hover:bg-red-700 text-white transition shadow"
        >
          <LogOut className="w-4 h-4" />
          <span>Đăng xuất</span>
        </button>
      </div>
    </nav>
  );
}
