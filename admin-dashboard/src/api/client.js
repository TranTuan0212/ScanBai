import axios from 'axios';

// Automatically detect host IP (e.g. 192.168.x.x:3000) or use custom stored Server URL
export const getBaseUrl = () => {
  const custom = localStorage.getItem('server_api_url');
  if (custom) return custom;
  const hostname = window.location.hostname || 'localhost';
  return `http://${hostname}:3000/api`;
};

const api = axios.create();

api.interceptors.request.use((config) => {
  config.baseURL = getBaseUrl();
  const token = localStorage.getItem('admin_token');
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

api.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response && error.response.status === 401) {
      localStorage.removeItem('admin_token');
      localStorage.removeItem('admin_user');
      if (window.location.pathname !== '/login') {
        window.location.href = '/login';
      }
    }
    return Promise.reject(error);
  }
);

export default api;
