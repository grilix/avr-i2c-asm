; vim:syntax=avr8bit

; Registers usage:
;   r2: return status
;   r4: arguments

.nolist
.include "inc/tn85def.inc"
.list

.equ     I2C_TARGET_ADDRESS = 0b01000000 ; pcf
; .equ     I2C_TARGET_ADDRESS = (0x60<<1) ; simulator lcd screen
; .equ     I2C_TARGET_ADDRESS = 0b10101010 ; random address
.equ     I2C_BYTE_TO_SEND   = 0b01000000

.equ     I2C_SDA         = PORTB0
.equ     I2C_SCL         = PORTB2
.equ     I2C_WRITE       = 0
.equ     I2C_READ        = 1
.equ     MSB             = 7 ; Most significant bit
.equ     LSB             = 0 ; Least significant bit

.org 0x0000
rjmp     main                ; Reset - Address 0
reti                         ; INT0 (address 01)
reti                         ; Pin Change Interrupt Request 0
reti                         ; Timer/Counter1 Compare Match A
reti                         ; Timer/Counter1 Overflow
reti                         ; Timer/Counter0 Overflow
reti                         ; EEPROM Ready
reti                         ; Analog Comparator
reti                         ; ADC Conversion Complete
reti                         ; Timer/Counter1 Compare Match B
reti                         ; Timer/Counter0 Compare Match A
reti                         ; Timer/Counter0 Compare Match B
reti                         ; Watchdog Timeout
reti                         ; USI START
reti                         ; USI Overflow

i2c_init:
  ; TODO: consider using USIWM0=1?
  ldi    r16, (0<<USISIE) | (0<<USIOIE) | \
              (1<<USIWM1) | (0<<USIWM0) | \
              (0<<USICS1) | (0<<USICS0) | (0<<USICLK) | (0<<USITC)
  out    USICR, r16

  in     r16, USISR
  cbr    r16, (1<<USICNT3) | (1<<USICNT2) | (1<<USICNT1) | (1<<USICNT0)
  sbr    r16, (0<<USICNT3) | (0<<USICNT2) | (0<<USICNT1) | (0<<USICNT0)
  out    USISR, r16

  ret

i2c_start_and_send_byte:
  in     r16, DDRB
  sbr    r16, (1<<I2C_SDA) | (1<<I2C_SCL)
  in     r17, PORTB
  sbr    r17, (1<<I2C_SDA) | (1<<I2C_SCL)
  out    PORTB, r17
  out    DDRB, r16

wait_scl:
  sbis   PINB, I2C_SCL
  rjmp   wait_scl

  sbis   USISR, USIPF        ; if flag not set, continue
  rjmp   start_clear

wait_stop:                   ; Wait for a stop condition
  sbis   USISR, USIPF
  rjmp   wait_stop
  nop

start_clear:                 ; Line clear, we can start
  ; Start condition
  sbi    DDRB, I2C_SDA       ; We take control of SDA
  cbi    USIDR, MSB          ; and clear the MSB to pull the line down
  nop
  sbi    DDRB, I2C_SCL       ; We take control of SCL
  cbi    PORTB, I2C_SCL      ; and clear the pin to pull the line down
  nop

i2c_send_byte:
  in     r16, USISR
  cbr    r16, (1<<USICNT3) | (1<<USICNT2) | (1<<USICNT1) | (1<<USICNT0)
  sbr    r16, (1<<USICNT3) | (0<<USICNT2) | (0<<USICNT1) | (0<<USICNT0)
  out    USISR, r16          ; Set counter for 8 bits

  out    USIDR, r4           ; Load data to send

  sbi    DDRB, I2C_SDA       ; Take control of SDA
  sbi    USISR, USIOIF       ; Clear overflow flag

i2c_transfer_loop:           ; Transfer until counter overflow, wait for ACK and return.
                             ; At this point, we assume:
                             ;      - USIDR:  Has the data ready to be transferred.
                             ;      - USICNT: Has the counter on correct state.
                             ;      - SCL:    Is down (0)
                             ;      - SDA:    Has the MSB of USIDR
                             ;
  sbi    USICR, USITC        ; To transfer the next bit, we release SCL,
transfer_wait_scl:           ; then wait for it to go up. Nodes can pull SCL down if they
                             ; need time. We can't continue until SCL is up anyways.
                             ; TODO: timeout, error
  nop
  sbis   PINB, I2C_SCL       ; If SCL hasn't gone up,
  rjmp   transfer_wait_scl   ; retry in a couple of instructions.
  nop

                             ; SCL is now up and some time (hopefully enough) has passed,
                             ; we can now pull SCL down and continue.
  sbi    USICR, USITC        ; Pull clock down
  sbi    USICR, USICLK       ; Advance the data counter
  nop

  sbis   USISR, USIOIF       ; If data counter didn't overflow,
  rjmp   i2c_transfer_loop   ; send next bit.

  ;  ********** ACK           -----------------------------
                             ; Transfer is complete, move on to ACK check.
                             ; At this point, we now assume:
                             ;      - SCL: Is down (0)

  cbi    DDRB, I2C_SDA       ; Release SDA
  sbi    USICR, USITC        ; Release SCL
  nop

  in     r16, PINB
  bst    r16, I2C_SDA        ; SDA: 0=ACK, 1=NACK
  nop

  sbi    USICR, USITC        ; Pull SCL down
  sbi    DDRB, I2C_SDA       ; Take back control of SDA

  brtc   i2c_ack_pass

  ldi    r16, 1
  mov    r2,  r16            ; Store error on r2

  ret

i2c_ack_pass:
                             ; ACK:
                             ;   - clock down
                             ;   - sda down
  nop
  nop
  ldi    r16, 0
  mov    r2,  r16
  ret

i2c_stop:                    ; Set stop condition.
                             ; The stop condition requires a change from low to high on SDA
                             ; while SCL is up. If SDA is high, we need to make sure SCL is
                             ; low at the moment SDA is changed.

  sbis   PINB, I2C_SDA       ; Do we need to pull sda down? (we could safely skip this check
                             ; and just do it.)
  rjmp   i2c_do_stop

  ; Pull both SCL&SDA down
  in     r16, PORTB
  cbr    r16, (1<<I2C_SDA) | (1<<I2C_SCL)
  out    PORTB, r16
  nop
  nop

i2c_do_stop:
  cbi    DDRB, I2C_SCL
  nop
  nop
  cbi    DDRB, I2C_SDA
  nop

  ret

main:
                             ; Load Stack register.
  ldi    r16, high(RAMEND)   ; Upper byte
  out    SPH, r16
  ldi    r16, low(RAMEND)    ; Lower byte
  out    SPL, r16

  rcall  i2c_init

  ldi    r16, I2C_TARGET_ADDRESS
  ; TODO, set W/R mode: LSB is: 0=write, 1=read
  mov    r4, r16

  rcall  i2c_start_and_send_byte

  ldi    r16, 0
  cpse   r16, r2
  rjmp   i2c_error

  ldi    r16, I2C_BYTE_TO_SEND
  rcall  i2c_send_byte

i2c_error:
  rcall  i2c_stop

loop:
  rjmp   loop
