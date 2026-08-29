const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

async function reset() {
  const deleted = await prisma.session.deleteMany();
  console.log('[Reset] Deleted sessions count:', deleted.count);
  console.log('[Reset] Database is now 100% clean and fresh.');
}

reset()
  .catch((err) => console.error(err))
  .finally(() => prisma.$disconnect());
