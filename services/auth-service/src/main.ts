import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { AppModule } from './app.module'; // verify app.module.ts exists in src directory

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.useGlobalPipes(new ValidationPipe()); // validates all DTOs automatically
  await app.listen(3001);
}
bootstrap();