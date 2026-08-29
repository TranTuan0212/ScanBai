const { PrismaClient } = require('@prisma/client');
const bcrypt = require('bcryptjs');

const prisma = new PrismaClient();

async function main() {
  const tenYearsLater = new Date();
  tenYearsLater.setFullYear(tenYearsLater.getFullYear() + 10);

  // 1. Create Admin Account
  const adminEmail = 'admin@cardlink.com';
  const adminHashedPassword = await bcrypt.hash('admin123', 10);
  const admin = await prisma.user.upsert({
    where: { email: adminEmail },
    update: {
      password: adminHashedPassword,
      role: 'admin',
      expiredAt: tenYearsLater
    },
    create: {
      email: adminEmail,
      password: adminHashedPassword,
      role: 'admin',
      expiredAt: tenYearsLater
    }
  });
  console.log(`[Seed] Admin user ready: ${admin.email} (role: ${admin.role})`);

  // 2. Create Standard Live Broadcaster Account
  const userEmail = 'user@cardlink.com';
  const userHashedPassword = await bcrypt.hash('password123', 10);
  const user = await prisma.user.upsert({
    where: { email: userEmail },
    update: {
      password: userHashedPassword,
      role: 'live',
      expiredAt: tenYearsLater
    },
    create: {
      email: userEmail,
      password: userHashedPassword,
      role: 'live',
      expiredAt: tenYearsLater
    }
  });
  console.log(`[Seed] Live user ready: ${user.email} (role: ${user.role})`);
}

main()
  .catch((e) => {
    console.error('[Seed Error]', e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
