import { Injectable } from '@nestjs/common';
import { UsersService } from '../users/users.service';
import { JwtService } from '@nestjs/jwt';
import { LoginDto } from './dto/login.dto';
import { RegisterDto } from './dto/register.dto';
import * as bcrypt from 'bcrypt';

@Injectable()
export class AuthService {
  constructor(
    private usersService: UsersService,
    private jwtService: JwtService,
  ) {}

  async validateUser(loginDto: LoginDto) {
    const user = await this.usersService.findByEmail(loginDto.email);
    if (user && await bcrypt.compare(loginDto.password, user.password_hash)) {
      const payload = { sub: user.id, email: user.email, role: user.role };
      return { access_token: this.jwtService.sign(payload) };
    }
    return { error: 'Invalid credentials' };
  }

  async register(registerDto: RegisterDto) {
    const user = await this.usersService.create(registerDto);
    const payload = { sub: user.id, email: user.email, role: user.role };
    return { access_token: this.jwtService.sign(payload) };
  }
}