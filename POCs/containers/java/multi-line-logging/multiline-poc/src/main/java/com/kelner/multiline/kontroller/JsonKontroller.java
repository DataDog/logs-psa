package com.kelner.multiline.kontroller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

@RestController
public class JsonKontroller {

    @GetMapping("/json")
    public ResponseEntity<String> throwException() {

        int x = 1 / 0;
        return ResponseEntity.ok("1 / 0=" + x);
    }

}
