#define N 3
#define NULL_SIGNAL 0
#define FINAL_ANGLE_SPEED 3
#define FINAL_SPEED 3
#define COUNT_FOR_LANDING 10

#define COMMAND_TURNING_ON 1
#define COMMAND_TURNING_OFF 2
#define COMMAND_RELOAD 3

#define BIUSL_NUM 0
#define ENGINE_NUM 1
#define BKU_NUM 2

chan biusCommands = [N] of {byte};
chan biusData = [N] of {byte};
chan engineCommands = [N] of {byte};
chan engineData = [N] of {byte};

byte nextComponent = 0; // Номер следующей компоненты для опроса средой

bool isBiuslTurnedOn = 0;  // Включен ли БИУС-Л
bool biuslShouldBeTurnedOn = 0;
bool biuslShouldBeReloaded = 0; // Должен ли быть перезагружен БИУС-Л
bool isEngineTurnedOn = 0;
bool shouldGoToOrbit = 0; // Поступили ли данные для перехода на эллиптическую орбиту
bool isOnOrbit = 0;

inline readData(channel, data) {
    do
    :: (len(channel) > 0) ->
        channel ? data;
    :: else -> break;
    od
}

inline clearChannel(channel) { // Метод для очистки канала при перезагрузке
    byte tmp;
    readData(channel, tmp);
}

// Компонент БКУ
active proctype BKU() {
  bool wasNotEverLanding = 1;
  bool shouldStartLanding = 0; // Поступила ли заявка на посадку
  bool isLanding = 0;
  byte angleSpeed;  // Угловая скорость от БИУС-Л
  byte speed;  // Скорость от двигателя
  byte countForLanding = 0; // Счетчик, при увеличении которого до значения COUNT_FOR_LANDING поступает заявка на посадку
  bool isReloadCommandAlreadySent = 0;
  bool shouldCommandBeSent = 0;
  
  do
  :: {
  nextComponent == BKU_NUM ->
    if
    :: (countForLanding < COUNT_FOR_LANDING) -> {
        countForLanding = countForLanding + 1;
        if
        :: (countForLanding == COUNT_FOR_LANDING) ->  {
            shouldStartLanding = 1;
            shouldCommandBeSent = 1;
        }
        :: else -> skip;
        fi
        nextComponent = 0;
    }
  
    // Если наступила очередь опроса БКУ и есть запрос на посадку, а также каналы команд БИУС-Л и двигателя не заполнены,
    // то через каналы оправляем команды включения соответствующим модулям и делаем шаг на следующий по очереди компонент

    :: (shouldStartLanding && len(biusCommands) < N && len(engineCommands) < N) -> {
        biusCommands ! COMMAND_TURNING_ON;
        engineCommands ! COMMAND_TURNING_ON;
        shouldCommandBeSent = 0;
        biuslShouldBeTurnedOn = 1;
        shouldStartLanding = 0;
        isLanding = 1;
        nextComponent = 0;
    }
    // Если наступила очередь опроса БКУ и поступили данные для перехода на эллиптическую орбиту, а также каналы команд БИУС-Л и двигателя не заполнены,
    // то через каналы оправляем команды выключения соответствующим модулям и делаем шаг на следующий по очереди компонент
    :: (shouldGoToOrbit && len(biusCommands) < N && len(engineCommands) < N) -> {
        biusCommands ! COMMAND_TURNING_OFF;
        engineCommands ! COMMAND_TURNING_OFF;
        shouldCommandBeSent = 0;
        biuslShouldBeTurnedOn = 0;
        isOnOrbit = 1;
        shouldGoToOrbit = 0;
        isLanding = 0;
        nextComponent = 0;
    }
    // Если канал данных БИУС-Л заполнен, отправляем модулю БИУС-Л команду для перезагрзки и команду для последующего включения и делаем шаг на следующий по очереди компонент
    :: (len(biusData) >= N && !biuslShouldBeReloaded && !isReloadCommandAlreadySent) -> {
        biusCommands ! COMMAND_RELOAD;
        isReloadCommandAlreadySent = 1;
        biuslShouldBeReloaded = 1;
        shouldCommandBeSent = 0;
        if
        :: (!isLanding && shouldStartLanding) ->
            shouldCommandBeSent = 1;
        :: (isBiuslTurnedOn) -> {
          biusCommands ! COMMAND_TURNING_ON;
          //shouldCommandBeSent = 1;//
          biuslShouldBeTurnedOn = 1;
        }
        :: else -> skip;
        fi
        nextComponent = 0;
    }
//    :: (isLanding && !isBiuslTurnedOn && biuslShouldBeTurnedOn && len(biusCommands) < N) -> {//
//      biusCommands ! COMMAND_TURNING_ON;//
//      shouldCommandBeSent = 0;//
//      nextComponent = 0;//
//   }//

    // Если наступила очередь опроса БКУ и каналы команд БИУС-Л и двигателя не заполнены, то через каналы пытаемся получить данные,
    // при искомых значениях скорости и угловой скорости обновляем значение shouldGoToOrbit и делаем шаг на следующий по очереди компонент
    :: ((len(biusData) > 0 || len(engineData) > 0) && !shouldCommandBeSent && (countForLanding == COUNT_FOR_LANDING || len(biusData) >= N)) -> {
        if
        :: ((len(biusData) > 0) && (len(engineData) == 0)) ->
            readData(biusData, angleSpeed);
        :: ((len(engineData) > 0) && (len(biusData) == 0)) ->
            readData(engineData, speed);
        :: ((len(biusData) > 0 ) && (len(engineData) > 0)) -> {
            readData(biusData, angleSpeed);
            readData(engineData, speed);
        }
        :: else -> skip;
        fi
        
        if
        :: (angleSpeed == FINAL_ANGLE_SPEED && speed == FINAL_SPEED && !isOnOrbit && !shouldGoToOrbit) ->
            shouldGoToOrbit = 1;
            shouldCommandBeSent = 1;
        :: else -> skip;
        fi
        nextComponent = 0;
    }
    :: else -> nextComponent = 0;
    fi
  }
  od
}

// Компонент БИУС-Л
active proctype BIUSL() {
  byte command; // Переменная для чтения команды из канала
  byte angleSpeed = 0;
  
  do
  :: {
  nextComponent == BIUSL_NUM ->
    // Если наступила очередь опроса БИУС-Л, и канал его команд не пуст,
    // то через канал читаем команду, делаем шаг на следующий по очереди компонент, если получили команду включения, обновляем переменные
    if
    :: (len(biusCommands) > 0) -> {
        biusCommands ? command;
        if
        :: (command == COMMAND_TURNING_ON) -> {
          biuslShouldBeTurnedOn = 0;
            isBiuslTurnedOn = 1;
        }
        :: (command == COMMAND_TURNING_OFF) ->
            isBiuslTurnedOn = 0;
        :: (command == COMMAND_RELOAD) -> {
            biuslShouldBeReloaded = 0;
            clearChannel(biusCommands);
            angleSpeed = 0;
            isBiuslTurnedOn = 0;
        }
        :: else -> skip;
        fi
        nextComponent = nextComponent + 1;
    }
    
    // Если наступила очередь опроса БИУС-Л и он выключен, а также канал его данных не заполнен,
    // то передаем нулевой сигнал и делаем шаг на следующий по очереди компонент

    :: (!isBiuslTurnedOn && len(biusData) < N && len(biusCommands) == 0) -> {
        biusData ! NULL_SIGNAL;
        nextComponent = nextComponent + 1;
    }
    // Если наступила очередь опроса БИУС-Л и он включен, а также канал его данных не заполнен,
    // то передаем значение угловой скорости по каналу и делаем шаг на следующий по очереди компонент,
    // а также обновляем угловую скорость (считаем, что в этот момент получаем данные от датчика)
    :: (isBiuslTurnedOn && len(biusData) < N  && len(biusCommands) == 0) -> {
        biusData ! angleSpeed;
        if
        :: (angleSpeed < FINAL_ANGLE_SPEED) ->
            angleSpeed = angleSpeed + 1;
        :: else -> skip;
        fi
        nextComponent = nextComponent + 1;
    }
    
    // Если наступила очередь опроса БИУС-Л и он не может получить или передать информацию, делаем шаг на следующий по очереди компонент
    :: else ->
        nextComponent = nextComponent + 1;
    fi
  }
  od
}

// Компонент Двигателя
active proctype Engine() {
  byte command; // Переменная для чтения команды из канала
  byte speed = 0;
  
  do
  :: {
  nextComponent == ENGINE_NUM ->
    // Если наступила очередь опроса двигателя , канал его команд не пуст,
    // то через канал читаем команду, делаем шаг на следующий по очереди компонент, если получили команду включения, обновляем соответствующую переменную
    if
    :: (len(engineCommands) > 0) -> {
        engineCommands ? command;
        if
        :: (command == COMMAND_TURNING_ON) ->
            isEngineTurnedOn = 1;
        :: (command == COMMAND_TURNING_OFF) ->
            isEngineTurnedOn = 0;
        :: else -> skip;
        fi
        nextComponent = nextComponent + 1;
    }
    
    // Если наступила очередь опроса двигателя и он включен, а также канал его данных не заполнен,
    // то передаем значение скорости по каналу и делаем шаг на следующий по очереди компонент,
    // а также обновляем скорость
    :: (isEngineTurnedOn && len(engineData) < N && len(engineCommands) == 0) -> {
        engineData ! speed;
        if
        :: (speed < FINAL_SPEED) ->
            speed = speed + 1;
        :: else -> skip;
        fi
        nextComponent = nextComponent + 1;
    }
    // Если наступила очередь опроса двигателя и он не может получить или передать информацию, делаем шаг на следующий по очереди компонент
    :: else -> nextComponent = nextComponent + 1;
    fi
  }
  od
}

// Когда-то в будущем наступит постоянно повторяющееся состояние, при котором БИУС-Л должен быть перезагружен, но будет выключен
ltl correctlyStartBiusl {[](biuslShouldBeTurnedOn -> <>isBiuslTurnedOn)};
ltl correctlyGoToOrbit {<>[](isOnOrbit && !isBiuslTurnedOn && !isEngineTurnedOn)};
